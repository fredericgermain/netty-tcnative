# Alpine / musl reproduction harness

Tooling used to diagnose and verify why the glibc-built `netty-tcnative` artifacts fail to load
on Alpine, and to prove the fix. The fix itself is a separate branch —
[`musl-compat`](https://github.com/fredericgermain/netty-tcnative/tree/musl-compat), submitted as
[netty/netty-tcnative#997](https://github.com/netty/netty-tcnative/pull/997). **This branch is
the evidence and the tools, not the fix**; nothing here is proposed for upstream.

Start with [`REPORT.md`](REPORT.md) — the full findings, including the parts that turned out to be
wrong along the way.

## What it establishes

- `netty-transport-native-epoll` is **not** broken on Alpine; only `netty-tcnative-boringssl-static` is
- on aarch64 it does not fail cleanly — it **SIGSEGVs the JVM** inside `dlopen`, so an application
  cannot catch it and fall back. `results/evidence-hs_err-*.log` is the crash
- installing `gcompat` does **not** fix aarch64, for a non-obvious reason (see REPORT.md §2)
- the fix costs no ABI reach: a CentOS 6 build keeps a `GLIBC_2.12` floor

## Layout

| path | purpose |
|---|---|
| `REPORT.md` | findings, per-arch failure modes, results matrix, dead ends |
| `run-matrix.sh` | driver: `{arm64,amd64} × {bare, libc6-compat, gcompat, full}` |
| `in-container.sh` | the per-variant sweep that runs inside each container |
| `elf-scan.sh` | `DT_NEEDED` + `ldd` + unresolvable-GLOBAL-symbol report |
| `verify-built-lib.sh` | checks a freshly built tree: arch, static linkage, post-link step, strip |
| `patch-released-jar.sh` | fixes a **released** classifier jar by ELF surgery, no rebuild |
| `fetch-jars.sh` | pulls the artifacts under test from Maven Central |
| `summarize.sh` | renders `results/*.log` into the report tables |
| `src/AlpineNativeLoadTest.java` | levels A/B/C — raw `System.load`, real API, functional context |
| `src/TlsHandshakeTest.java` | level D — full TLS handshake plus application data |
| `shim/musl_shim.c` | weak-symbol shim; `LD_PRELOAD` workaround and template for the in-tree fix |
| `Dockerfile.alpine` | musl target; `--build-arg EXTRA_PKGS=` selects bare/gcompat/full |
| `Dockerfile.glibc` | glibc control image |
| `Dockerfile.tcnative-build` | local build image (Rocky 8), for iterating without the release images |

## Running it

```sh
./fetch-jars.sh                 # artifacts + async-profiler as a positive control
./run-matrix.sh --arch arm64    # native on Apple Silicon
./run-matrix.sh --arch amd64    # emulated; slow
./run-matrix.sh --glibc         # control: everything must PASS here
./summarize.sh                  # regenerate the tables
```

Override the versions under test without editing anything:

```sh
TCNATIVE_VERSIONS=2.0.82.Final-SNAPSHOT EPOLL_VERSIONS=4.2.12.Final ./run-matrix.sh --arch arm64
```

Level D needs `netty-pkitesting` on the classpath for `SelfSignedCertificate`; `fetch-jars.sh`
already pulls it.

## Things that will bite you

- **Clean the tree when switching architecture.** The APR and BoringSSL build steps guard on
  directory existence, so reusing another arch's `target/` silently produces a "static" library
  dynamically linked against the host's system OpenSSL — and every step reports success.
- **`readelf --dyn-syms` needs `-W`**, or long symbol names are truncated with `[...]`.
- **A static symbol scan over-reports.** Symbols in lazy PLT slots that nothing calls are
  harmless; trust `ldd` and the runtime tests.
- **`docker/Dockerfile.centos6` needs a host kernel that still emulates the legacy vsyscall page.**
  Without it, CentOS 6 userspace SIGSEGVs on the image's first `sed -i` while `sed --version`
  still works. Ubuntu kernels have it; some cloud kernels do not.
- Docker's default bridge may have no outbound TCP if a Kubernetes CNI has set
  `-P FORWARD DROP`; `--network=host` sidesteps it.

## Also on this branch

`docker/Dockerfile.centos7` and `docker/docker-compose.centos-7-x86_64.yaml` — a native x86_64
build on the same CentOS 7 base as the aarch64 cross image, for hosts that cannot build the
CentOS 6 image. **Deliberately excluded from the upstream PR**: it raises that artifact's glibc
floor from `GLIBC_2.12` to a measured `GLIBC_2.16`, dropping RHEL 6 and Ubuntu 12.04, and
`pom.xml` documents releasing x86_64 from RHEL 6 precisely to keep that reach. Kept here because
it is the only way to build x86_64 on a host you cannot reboot. It needs two things the aarch64
image does not: an SCL devtoolset (CentOS 7's system gcc 4.8.5 is too old for BoringSSL) and
`no-asm` for OpenSSL (binutils 2.27 cannot assemble OpenSSL 3.6's AVX-512 sources).

## Not included

`libs/` (~26 MB of jars — run `fetch-jars.sh`), and the bulky Maven build logs. `results/` keeps
only `summary.tsv` and the crash evidence.
