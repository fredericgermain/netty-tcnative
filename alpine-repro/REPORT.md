# Netty natives on Alpine/musl — reproduction & diagnosis

Reproduced on `eclipse-temurin:21.0.11_10-jdk-alpine-3.23` (musl **1.2.5-r23**, gcompat
**1.1.0-r4**) on both architectures, against the released artifacts from Maven Central.
Harness and raw logs live beside this file.

**Status: diagnosed, fixed, committed.** The fix is verified end-to-end from source on
**both** aarch64 and x86_64 — see §6. arm64 work ran natively on the workstation; x86_64
diagnosis ran under qemu and the x86_64 *build* on a native x86_64 host, since emulating the
Maven JVM proved impractical.

Shipped as branch `musl-compat` on `fredericgermain/netty-tcnative` (rebased onto upstream
`990751e`, merges cleanly). Maintainer-facing rules live in the repo itself at
`docs/musl-compatibility.md` — that is the document to keep current, not this one.

**Remaining validation gap:** both builds used Rocky 8 (glibc 2.28), not upstream's official
CentOS 6 / CentOS 7-cross images (glibc 2.12/2.17). The fix is glibc-version-agnostic, but a
PR should be built on the official images to preserve old-glibc compatibility. That needs a
native x86_64 host; the attempt was blocked when the VPN to the build host dropped.

---

## 1. Verdict

**`netty-transport-native-epoll` is not broken on Alpine.** It loads and reports
`Epoll.isAvailable() == true` on *bare* Alpine — no `gcompat`, no `libc6-compat` — on both
architectures, at both 4.2.12.Final and 4.2.17.Final. Nothing to fix.

**`netty-tcnative-boringssl-static` is broken, and it is not fixed in the latest release.**

| | checkout version | latest release |
|---|---|---|
| netty epoll | 4.2.12.Final — **works** | 4.2.17.Final — **works** |
| netty-tcnative | 2.0.75.Final — **broken** | 2.0.81.Final — **still broken** |

The tcnative breakage has two distinct failure modes, one per architecture, and they need
different fixes. On **aarch64 it is not a clean failure — it SIGSEGVs the JVM**, and
installing `gcompat` does not help.

---

## 2. What actually breaks

### The rule that governs everything: musl's reserved library names

musl's dynamic linker satisfies a fixed set of libc alias names from musl itself, without
ever touching the filesystem — `ldso/dynlink.c:1074-1084`:

```c
/* Catch and block attempts to reload the implementation itself */
if (name[0]=='l' && name[1]=='i' && name[2]=='b') {
    static const char reserved[] = "c.pthread.rt.m.dl.util.xnet.";
```

So a `DT_NEEDED` of `libc.so.6`, `libpthread.so.0`, `librt.so.1` or `libdl.so.2` is **fine**
on bare Alpine. What is not fine is any name outside that list.

`gcompat` installs its shim under exactly those names:

```
/lib/libc.so.6      -> libgcompat.so.0
/lib/libcrypt.so.1  -> libgcompat.so.0
/lib/libm.so.6      -> libgcompat.so.0
/lib/librt.so.1     -> libgcompat.so.0     ...
/lib/ld-linux-aarch64.so.1  (real file)
```

**`libc.so.6` is reserved, so musl short-circuits it to itself and gcompat's symlink is
never read.** Only a *non-reserved* name actually pulls `libgcompat.so.0` into the process.
That single fact explains the entire regression.

### The regression: `libcrypt.so.1` was the accidental gcompat loader

`DT_NEEDED` across tcnative releases:

| version | aarch64 | x86_64 |
|---|---|---|
| 2.0.65 | librt, **libcrypt.so.1**, libdl, libc | librt, libpthread, libdl, libc |
| 2.0.73 / 2.0.75 / 2.0.81 | librt, libdl, **libgcc_s.so.1**, libc | librt, libpthread, libdl, **libgcc_s.so.1**, libc, **ld-linux-x86-64.so.2** |

On 2.0.65/aarch64, `libcrypt.so.1` is not reserved → real file lookup → resolves to
`libgcompat.so.0` → `__getauxval` resolves → everything works. Observed directly:

```
2.0.65 + gcompat:  libcrypt.so.1 => /lib/libcrypt.so.1   (-> libgcompat.so.0)   OK
2.0.73 + gcompat:  libc.so.6     => /lib/ld-musl-aarch64.so.1
                   Error relocating ...: __getauxval: symbol not found
```

Dropping `libcrypt.so.1` removed the only thing that was loading gcompat. That is the "bad
symbol link".

### aarch64: a JVM crash, not a load error

`__getauxval` is unresolved, and it is called from an **ELF init constructor** that runs
during `dlopen` — libgcc's ARM64 outline-atomics probe, statically linked into the `.so`:

```
C  [libnetty_tcnative_linux_aarch_64.so+0x2466c]  init_have_lse_atomics+0xc
C  [ld-musl-aarch64.so.1+0x6b1cc]
C  [ld-musl-aarch64.so.1+0x6cedc]  dlopen+0xc4
V  [libjvm.so+0xbb9608]  os::Linux::dlopen_helper(...)
```

So the application does not get an `UnsatisfiedLinkError` it could catch and fall back
from — the JVM dies with SIGSEGV and writes a ~400 MB core. This happens on **bare,
`libc6-compat`, `gcompat` and `full`** variants alike. Full crash log:
`results/evidence-hs_err-tcnative-2.0.73-aarch64.log`.

### x86_64: a clean failure, fixed by gcompat

Here the blocker is `DT_NEEDED: ld-linux-x86-64.so.2`, which does not begin with `lib` and
so is a real file lookup. `gcompat` ships that file, so installing it resolves everything —
all four tcnative versions pass on x86_64 with `gcompat`.

Note `apk add libc6-compat` on Alpine 3.23 **installs gcompat** — the two are the same
package, so those two columns are identical by construction.

---

## 3. Results matrix

Cells are the real-API verdict (`OpenSsl.isAvailable()` / `Epoll.isAvailable()`).

| artifact | version | x86_64 bare | x86_64 gcompat | aarch64 bare | aarch64 gcompat | glibc control |
|---|---|---|---|---|---|---|
| epoll | 4.2.12.Final | PASS | PASS | PASS | PASS | PASS |
| epoll | 4.2.17.Final | PASS | PASS | PASS | PASS | PASS |
| tcnative | 2.0.65.Final | PASS | PASS | FAIL `libcrypt.so.1` missing | PASS | PASS |
| tcnative | 2.0.73.Final | FAIL `ld-linux-x86-64.so.2` | PASS | **JVM SIGSEGV** | **JVM SIGSEGV** | PASS |
| tcnative | 2.0.75.Final | FAIL `ld-linux-x86-64.so.2` | PASS | **JVM SIGSEGV** | **JVM SIGSEGV** | PASS |
| tcnative | 2.0.81.Final | FAIL `ld-linux-x86-64.so.2` | PASS | **JVM SIGSEGV** | **JVM SIGSEGV** | PASS |
| asyncProfiler 4.1 *(control)* | — | PASS | PASS | PASS | PASS | PASS |

The `libc6-compat` and `full` columns are omitted because they carry no extra information:
on Alpine 3.23 `libc6-compat` is a `provides` of **gcompat**, so that variant installs
gcompat, and `full` only adds `libstdc++`/`libgcc` on top. Where they were run they matched
the gcompat column result-for-result: `arm64/libc6-compat`, `arm64/full` and
`amd64/libc6-compat` are all byte-identical to their gcompat counterpart.

**One cell was not collected: `amd64/full`.** Its image would not build — under qemu the
`APKINDEX` fetch times out and apk then reports every requested package as missing. Given
`amd64/gcompat` is complete and the other three equivalences hold, this is a redundant
data point, not a gap in the conclusions.

Symbols musl cannot resolve, on bare Alpine:

| library | aarch64 | x86_64 |
|---|---|---|
| epoll 4.2.12 / 4.2.17 | none | none |
| tcnative 2.0.65 → 2.0.81 | `__getauxval`, `fopen64` | `__isinf`, `__isnan`, `__strdup`, `fopen64` |
| libasyncProfiler 4.1 | none | none |

Feasibility probe — each half of the async-profiler recipe fixes one architecture:

| target | +patchelf | +patchelf +shim |
|---|---|---|
| tcnative 2.0.73 / 2.0.75 / 2.0.81, x86_64 | **PASS** | PASS |
| tcnative 2.0.73 / 2.0.75 / 2.0.81, aarch64 | JVM SIGSEGV | **PASS** |
| tcnative 2.0.65, aarch64 | FAIL (`libcrypt.so.1`) | FAIL (`libcrypt.so.1`) |

---

## 4. Workarounds that work today

1. **x86_64, any tcnative version** — `apk add gcompat`. Complete fix, verified.
2. **aarch64, tcnative ≥ 2.0.73** — gcompat does **not** work. Two verified options:
   - Pin to **2.0.65.Final** *and* install `gcompat` (needs the `libcrypt.so.1` link), or
   - `LD_PRELOAD` a ~10-line shim supplying `__getauxval`. Verified against the
     **unmodified released jar** on bare Alpine:
     ```
     tcnative/2.0.75.Final/aarch64/bare+shimonly  B-openssl  PASS  OpenSsl.isAvailable()=true BoringSSL
     tcnative/2.0.81.Final/aarch64/bare+shimonly  B-openssl  PASS  OpenSsl.isAvailable()=true BoringSSL
     ```
     Source: `shim/musl_shim.c`. No rebuild, no gcompat, no patched artifact.
3. **epoll** — nothing needed.

---

## 5. Recommended fix (evidence for the follow-up)

The [async-profiler recipe](https://github.com/async-profiler/async-profiler/issues/952) —
one binary for glibc and musl — is sufficient here. Both halves were tested against the
released artifacts; each fixes exactly one architecture:

| step | effect |
|---|---|
| `patchelf --remove-needed ld-linux-x86-64.so.2` | **fixes x86_64** on its own, all versions |
| supply `__getauxval` (weak symbol / shim) | **fixes aarch64** on its own, all versions |

Applied to the real jars on bare Alpine, both architectures load. This says the fix belongs
in the **build**, not in a new musl classifier:

- **aarch64 — kill the crashing constructor.** `init_have_lse_atomics` lives *inside*
  tcnative's own `.so`: libgcc's ARM64 outline-atomics support is already statically linked
  in, and it calls `__getauxval` from an init constructor. So `-static-libgcc` does not
  remove it — static linking is what put it there. Either compile with
  **`-mno-outline-atomics`** so the LSE probe is never linked in, or ship a **weak
  `__getauxval`**, which is exactly async-profiler's `__sprintf_chk` trick. The shim probe
  proves the second option works.
- **x86_64 — strip the `ld-linux-*` `DT_NEEDED`** after link, as `Makefile:156` does.
- `-static-libgcc` is still worth having: it drops the `libgcc_s.so.1` `DT_NEEDED`, which is
  not musl-reserved and therefore needs Alpine's `libgcc` package present.
- Weak fallbacks for the remaining glibc-internal imports (`fopen64`, `__isinf`, `__isnan`,
  `__strdup`, `__pthread_key_create`) are cheap insurance — currently harmless only because
  nothing calls them (see the caveat below).

`libasyncProfiler.so` was carried through the identical harness as a positive control and
passes on bare Alpine on both arches, confirming the approach is sound and the scanner is
not simply reporting everything as clean.

### Why epoll is clean and tcnative is not

The obvious question is why `epoll` needs none of this. It is not a difference in compile
flags — it is a difference in what each library *contains*:

| | epoll 4.2.17 x86_64 | tcnative 2.0.81 x86_64 |
|---|---|---|
| size | 106 KB | 3.0 MB |
| `DT_NEEDED` | `libdl.so.2 librt.so.1 libc.so.6` (all reserved) | + `libgcc_s.so.1`, `ld-linux-x86-64.so.2` |
| `_Unwind_*` (C++ unwinder) | 0 | 11 |
| `__tls_get_addr` (dynamic TLS) | 0 | 1 |

epoll is pure C with no TLS and no C++, so nothing references a symbol that only `ld.so`
defines. tcnative statically absorbs BoringSSL (C++), APR and `libstdc++.a`, which drag in
the exception unwinder and dynamic TLS.

All four appear together, and only from 2.0.73 onward:

| version | `__tls_get_addr` | `_Unwind_*` | `ld-linux` NEEDED | `libgcc_s` NEEDED |
|---|---|---|---|---|
| 2.0.65 | 0 | 0 | 0 | 0 |
| 2.0.73 / 2.0.75 / 2.0.81 | 1 | 11 | 1 | 1 |

**The `ld-linux` dependency is spurious on musl.** `__tls_get_addr@GLIBC_2.3` is defined in
`ld-linux-x86-64.so.2` on glibc, so the linker records that file as `DT_NEEDED` — but musl
defines the symbol itself (`T __tls_get_addr` in `ld-musl-x86_64.so.1`). Only the *filename*
lookup fails, never the symbol, which is exactly why `patchelf --remove-needed` alone fixes
every x86_64 version.

Trying to avoid `__tls_get_addr` at the source with `-ftls-model=initial-exec` is **not** a
safe alternative: initial-exec TLS in a `dlopen`'d library can fail at load once the static
TLS block is exhausted. Stripping the `DT_NEEDED` is the pragmatic fix, and is what
async-profiler does.

Also note the build passes `-static-libstdc++` but **never `-static-libgcc`**
(`boringssl-static/pom.xml:585` and `:995`), which is why `libgcc_s.so.1` is still a dynamic
dependency. It happened not to block us only because the temurin Alpine image ships the
`libgcc` package; a minimal Alpine would fail here too.

### The `-lcrypt` removal upstream

The build itself echoes `Patching APR to not link against libcrypt` — `patches/apr_crypt.patch`
drops `AC_SEARCH_LIBS(crypt, crypt ufc)` from APR's `configure.in`, added in
`8d46f00` "Patch APR to remove crypt dependency (#758)", first released in 2.0.56. That is
an upstream change of exactly the shape that removes `libcrypt.so.1` from `DT_NEEDED`, and
therefore removes the accidental `libgcompat.so.0` load on Alpine.

Stated precisely: **the aarch64 artifact still carried `libcrypt.so.1` at 2.0.65 and had lost
it by 2.0.73**, and the exact commit responsible for that particular delta was not pinned —
the aarch64 and x86_64 pipelines source APR differently, so the timing differs per arch. The
measured `DT_NEEDED` tables above are the evidence; this paragraph is the upstream context.

### Static-scan caveat

`elf-scan.sh` lists symbols musl does not export; that set is a **superset** of what
actually breaks. On x86_64, `__isinf`/`__isnan`/`__strdup`/`fopen64` are reported
unresolvable at 2.0.65 yet the library loads fine — those relocations are lazy PLT entries
that are never called. Only eagerly-resolved relocations and init-constructor calls are
fatal. Trust the RESULT lines over the symbol list.

---

## 6. The fix (implemented and verified)

Two independent deliverables.

### 6a. No-rebuild workaround — `patch-released-jar.sh`

Patches a **released** classifier jar by ELF surgery. Entry lists stay byte-identical.

| arch | action | result |
|---|---|---|
| x86_64 | `patchelf --remove-needed ld-linux-x86-64.so.2` | **PASS on bare Alpine**, no packages |
| aarch64 | `patchelf --add-needed libgcompat.so.0` | **PASS with `apk add gcompat`** |

The aarch64 form deliberately recreates 2.0.65's accident: a non-reserved `DT_NEEDED` is the
only way to get gcompat actually loaded. It also converts the SIGSEGV into a catchable
`UnsatisfiedLinkError` when gcompat is absent, which is a safety improvement on its own.

### 6b. Source fix — 3 files

| file | change |
|---|---|
| `openssl-dynamic/src/main/c/musl_compat.c` | **new.** `weak` + `visibility("default")` definitions of `__getauxval`, `fopen64`, `__isinf`, `__isnan`, `__strdup`. No autotools change needed — hawtjni scans `src/main/c` and generates `Makefile.am`. |
| `boringssl-static/pom.xml` | post-link `patchelf --remove-needed ld-linux-*` beside the existing `strip`, in the default profile's `native-jar` antrun target |
| `docker/Dockerfile.centos6` | patchelf via its prebuilt static binary (CentOS 6 is EOL, no EPEL, and `objcopy` cannot remove a `DT_NEEDED`) |

`__getauxval` is the load-fatal one. Verified in isolation before the full build: a
glibc-built library carrying libgcc's exact `init_have_lse_atomics` shape fails on bare Alpine
with `Error relocating: __getauxval: symbol not found`, and loads clean once `musl_compat.o`
is linked in — the symbol goes from `UND` to defined, leaving only `getauxval`, which musl
exports.

**Verified end-to-end on both architectures (source build `2.0.76.Final-SNAPSHOT`).** aarch64 built natively on the workstation, x86_64 on a native x86_64 host (see below). aarch64 results:

| check | before (released 2.0.81) | after |
|---|---|---|
| `elf-scan` unresolvable, bare Alpine | `__getauxval`, `fopen64` | **none** |
| `OpenSsl.isAvailable()`, bare Alpine | **JVM SIGSEGV** | **PASS** |
| functional TLS (`OpenSslClientContext`, 41 ciphers), bare Alpine | **JVM SIGSEGV** | **PASS** |
| glibc control | PASS | **PASS** (no regression) |
| repo `NativeTest` | — | PASS |

### x86_64 — built and verified end-to-end on native hardware

Emulating x86_64 on the Apple Silicon workstation was not viable (`qemu-x86_64` emulates the
whole Maven JVM; the build spent an hour inside `openssl-classes` without reaching BoringSSL).
The build was instead done on a **native x86_64 Debian 13 host, 12 cores**, over SSH.

The decisive before/after, from one build (`verify-built-lib.sh`):

```
== 1. BoringSSL static archives
   libssl.a:    architecture: i386:x86-64
   libcrypto.a: architecture: i386:x86-64
== 2. DT_NEEDED
   before patchelf: librt.so.1 libpthread.so.0 libdl.so.2 libgcc_s.so.1 libc.so.6 ld-linux-x86-64.so.2
   after  patchelf: librt.so.1 libpthread.so.0 libdl.so.2 libgcc_s.so.1 libc.so.6
   ok: no ld-linux entry
== 3. musl fallback symbols   WEAK/DEFAULT: __getauxval fopen64 __isinf __isnan __strdup
   ok: none still undefined
```

Runtime, on **bare** Alpine x86_64 (no gcompat, no `libc6-compat`):

| check | new build | released 2.0.81 |
|---|---|---|
| `elf-scan` unresolvable | **none** | `__isinf __isnan __strdup fopen64` |
| load (`System.load`) | **PASS** | FAIL |
| `OpenSsl.isAvailable()` | **PASS** BoringSSL | FAIL |
| functional TLS (`OpenSslClientContext`, 41 ciphers) | **PASS** | FAIL |
| glibc control (`temurin:21-jdk-jammy`) | **PASS** | PASS |
| repo `NativeTest` | **PASS** | — |

Note the BoringSSL archives are genuinely `i386:x86-64` and there is no `libssl.so`/
`libcrypto.so` in `DT_NEEDED` — i.e. this is a real static BoringSSL build, not the
stale-directory fallback described in §6c.

### 6d. Regression test on the standard temurin image

The earlier glibc control only checked that the library *loads* and that
`OpenSsl.isAvailable()` is true. That is too weak to call "no regression": it would not catch
a library that loads but whose crypto is broken. `src/TlsHandshakeTest.java` (Level D) drives
a **complete TLS handshake plus application data both ways** through BoringSSL, using an
in-memory `SSLEngine` pair — OpenSSL-backed server with a self-signed cert, OpenSSL-backed
client — so the negotiated suite and the decrypted payload are both asserted.

On `eclipse-temurin:21-jdk-jammy` (standard glibc image), the patched build is compared
directly against two released versions:

| tcnative | aarch64 glibc | x86_64 glibc |
|---|---|---|
| 2.0.75.Final (released) | PASS — TLSv1.3 / TLS_AES_128_GCM_SHA256 | PASS — same suite |
| 2.0.81.Final (released) | PASS — TLSv1.3 / TLS_AES_128_GCM_SHA256 | PASS — same suite |
| **2.0.76.Final-SNAPSHOT (patched)** | **PASS — identical suite, appdata ok both ways** | **PASS — identical** |

Load, `isAvailable`, and handshake are all PASS for all three on both architectures:
**no glibc regression**, and the patched build negotiates the identical cipher suite.

The same handshake on **bare Alpine (musl)** shows the fix is what makes the difference:

| tcnative | aarch64 bare musl | x86_64 bare musl |
|---|---|---|
| 2.0.81.Final (released) | **JVM SIGSEGV** | FAIL — cannot load |
| **2.0.76.Final-SNAPSHOT (patched)** | **PASS — full TLSv1.3 handshake, appdata ok** | **PASS — same** |

Two bugs in the test itself were fixed before trusting it, both real TLS 1.3 behaviours rather
than library faults: the client reaches `NOT_HANDSHAKING` while the server still sits in
`NEED_UNWRAP` awaiting optional post-handshake traffic (so an idle `NEED_UNWRAP` now counts as
settled), and the peer's first post-handshake record is a `NewSessionTicket`, so a single
`unwrap` legitimately yields zero application bytes (the unwrap now loops).

### What did NOT work: `-static-libgcc`

Adding `-static-libgcc` to drop the `libgcc_s.so.1` `DT_NEEDED` was tried and **reverted**.
It is a no-op in this build: the library links with the C driver, so the `_Unwind_*` symbols
pulled in by `libstdc++.a` remain `GLOBAL UND` and `libgcc_s.so.1` is genuinely required —
removing that entry would break the library. The flag *does* work in isolation
(`g++ -shared -static-libstdc++ -l:libstdc++.a -static-libgcc` drops it), so this is specific
to how the JNI library is linked. Alpine satisfies `libgcc_s.so.1` with the `libgcc` package,
which the temurin JDK images already install, so it was never the blocker. A comment in the
pom records this so nobody repeats it.

Related observation: `-l:libstdc++.a` is itself what introduces `ld-linux-aarch64.so.1` on
arm64 in an isolated link, so the patchelf step is worth keeping on both architectures even
though the released aarch64 artifact never carried that entry.

## 6c. Build-system trap worth knowing about

Both the APR and BoringSSL steps in `boringssl-static/pom.xml` guard on **directory
existence**, not on validity or target architecture:

```
[echo] APR was already build, skipping the build step.
[echo] BoringSSL was already build, skipping the build step.
```

Two distinct failures came out of this while building here:

1. **A run that fails partway leaves an empty `target/apr`**, after which every later run
   skips building APR and dies much further downstream with
   `configure: error: the --with-apr parameter is incorrect` — three layers away from the
   real cause.
2. **Worse: building a second architecture in the same tree silently produces a wrong
   artifact.** Reusing an aarch64 `target/boringssl-main` for an x86_64 build left
   `libssl.a`/`libcrypto.a` as aarch64 archives; the linker skipped them as incompatible,
   fell back to the host's *shared* system OpenSSL, and produced a "boringssl-static"
   library with `DT_NEEDED: libssl.so.1.1, libcrypto.so.1.1` and no bundled BoringSSL at
   all. It built and packaged successfully — nothing failed.

So: `rm -rf <module>/target` when switching architecture or after any failed run. Do not
trust an incremental rebuild here. Verifying `DT_NEEDED` on the produced `.so` catches
case 2 immediately, which is why that check is part of the verification below rather than an
afterthought.

## 7. Scope note

These are the **released** artifacts matching the checkout tags, not rebuilds of the working
trees (`netty` 4.2 @ `5f019e71ee`, `netty-tcnative` main @ `c2533ef`). Neither tree has
native-build changes after its tag, and both failure modes are visible in the shipped
binaries, so a source rebuild was not needed to characterise them. It *is* needed to
validate the fix in §5.

---

## 8. Reproducing

```bash
./fetch-jars.sh                 # pull artifacts from Maven Central
./run-matrix.sh --arch arm64    # native, fast
./run-matrix.sh --arch amd64    # qemu-emulated, slow
./run-matrix.sh --glibc         # control: everything must PASS
./summarize.sh                  # regenerate the tables above
```

Environment notes for this machine: Docker runs in Colima with k3s enabled, and
kube-router's `-P FORWARD DROP` blocks the default bridge, so the harness uses
`--network=host` (override with `NET=`). amd64 emulation required
`docker run --privileged tonistiigi/binfmt --install amd64`, which a `colima restart`
clears.

### Harness layout

| file | role |
|---|---|
| `fetch-jars.sh` | downloads the artifacts + async-profiler control |
| `Dockerfile.alpine` | test image; `EXTRA_PKGS` selects the variant |
| `Dockerfile.glibc` | glibc control image |
| `elf-scan.sh` | `DT_NEEDED` + `ldd` + unresolvable-symbol report, run inside the target |
| `src/AlpineNativeLoadTest.java` | Level A raw `System.load`, Level B real Netty API |
| `shim/musl_shim.c` | weak-symbol shim (workaround + feasibility probe) |
| `in-container.sh` | per-(arch,variant) sweep; survives JVM crashes |
| `run-matrix.sh` | drives the matrix |
