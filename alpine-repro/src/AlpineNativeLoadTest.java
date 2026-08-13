import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Reproduces Netty native-library load failures on Alpine/musl.
 *
 * Level A -- raw System.load() of the .so shipped inside the classifier jar. This is the
 *            dynamic-linking check: musl's loader reports "Error relocating ...: <sym>:
 *            symbol not found" or "Error loading shared library ...", and that text arrives
 *            verbatim in the UnsatisfiedLinkError.
 * Level B -- the real Netty API (Epoll / OpenSsl availability), i.e. what an application
 *            actually sees.
 *
 * Emits machine-readable lines:  RESULT <label> <level> PASS|FAIL <detail>
 */
public final class AlpineNativeLoadTest {

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: AlpineNativeLoadTest A <jar-or-so> <label>");
            System.err.println("       AlpineNativeLoadTest B epoll|openssl <label>");
            System.exit(2);
        }
        switch (args[0]) {
            case "A" -> levelA(args[1], args[2]);
            case "B" -> levelB(args[1], args[2]);
            case "C" -> levelC(args[1]);
            default -> throw new IllegalArgumentException("unknown mode: " + args[0]);
        }
    }

    // ---------------------------------------------------------------- Level A

    private static void levelA(String target, String label) {
        Path so;
        try {
            so = target.endsWith(".so") ? Path.of(target) : extractNativeLib(Path.of(target));
        } catch (Exception e) {
            result(label, "A", false, "extract-failed: " + e);
            return;
        }
        if (so == null) {
            result(label, "A", false, "no META-INF/native/*.so entry in " + target);
            return;
        }
        try {
            System.load(so.toAbsolutePath().toString());
            result(label, "A", true, "loaded " + so.getFileName());
        } catch (Throwable t) {
            // musl's relocation errors live in the message; keep it on one line.
            result(label, "A", false, t.getClass().getSimpleName() + ": " + oneLine(t.getMessage()));
        }
    }

    /** Pulls META-INF/native/<something>.so out of a Netty classifier jar. */
    private static Path extractNativeLib(Path jar) throws Exception {
        try (ZipFile zf = new ZipFile(jar.toFile())) {
            Enumeration<? extends ZipEntry> entries = zf.entries();
            while (entries.hasMoreElements()) {
                ZipEntry e = entries.nextElement();
                String n = e.getName();
                if (n.startsWith("META-INF/native/") && n.endsWith(".so")) {
                    Path out = Files.createTempDirectory("nativelib")
                            .resolve(n.substring(n.lastIndexOf('/') + 1));
                    try (InputStream in = zf.getInputStream(e)) {
                        Files.copy(in, out, StandardCopyOption.REPLACE_EXISTING);
                    }
                    out.toFile().setExecutable(true);
                    return out;
                }
            }
        }
        return null;
    }

    // ---------------------------------------------------------------- Level B

    /** {@code which} is "epoll", "openssl" or "both" -- the classpath only carries one at a time. */
    private static void levelB(String which, String label) {
        if (which.equals("epoll") || which.equals("both")) {
            checkEpoll(label);
        }
        if (which.equals("openssl") || which.equals("both")) {
            checkOpenSsl(label);
        }
    }

    private static void checkEpoll(String label) {
        try {
            Class<?> epoll = Class.forName("io.netty.channel.epoll.Epoll");
            boolean available = (Boolean) epoll.getMethod("isAvailable").invoke(null);
            if (available) {
                result(label, "B-epoll", true, "Epoll.isAvailable()=true");
            } else {
                Throwable cause = (Throwable) epoll.getMethod("unavailabilityCause").invoke(null);
                result(label, "B-epoll", false, rootMessage(cause));
            }
        } catch (Throwable t) {
            result(label, "B-epoll", false, "harness-error: " + oneLine(String.valueOf(t)));
        }
    }

    private static void checkOpenSsl(String label) {
        try {
            Class<?> openSsl = Class.forName("io.netty.handler.ssl.OpenSsl");
            boolean available = (Boolean) openSsl.getMethod("isAvailable").invoke(null);
            if (available) {
                String version = String.valueOf(openSsl.getMethod("versionString").invoke(null));
                result(label, "B-openssl", true, "OpenSsl.isAvailable()=true " + version);
            } else {
                Throwable cause = (Throwable) openSsl.getMethod("unavailabilityCause").invoke(null);
                result(label, "B-openssl", false, rootMessage(cause));
            }
        } catch (Throwable t) {
            result(label, "B-openssl", false, "harness-error: " + oneLine(String.valueOf(t)));
        }
    }

    // ---------------------------------------------------------------- Level C

    /**
     * Functional check: loading the library is not the same as it working. This drives real
     * BoringSSL/APR work -- enumerating cipher suites and building an OpenSSL-backed
     * SslContext -- so a library that dlopens but is broken inside still fails here.
     */
    private static void levelC(String label) {
        try {
            Class<?> openSsl = Class.forName("io.netty.handler.ssl.OpenSsl");
            if (!(Boolean) openSsl.getMethod("isAvailable").invoke(null)) {
                result(label, "C-tls", false, "OpenSsl unavailable: "
                        + rootMessage((Throwable) openSsl.getMethod("unavailabilityCause").invoke(null)));
                return;
            }
            String version = String.valueOf(openSsl.getMethod("versionString").invoke(null));
            @SuppressWarnings("unchecked")
            var ciphers = (java.util.Set<String>) openSsl.getMethod("availableJavaCipherSuites").invoke(null);

            // Build a real OpenSSL-backed client context; this initialises BoringSSL properly.
            Class<?> builderCls = Class.forName("io.netty.handler.ssl.SslContextBuilder");
            Class<?> providerCls = Class.forName("io.netty.handler.ssl.SslProvider");
            Class<?> insecureCls = Class.forName("io.netty.handler.ssl.util.InsecureTrustManagerFactory");

            Object builder = builderCls.getMethod("forClient").invoke(null);
            Object openSslProvider = Enum.valueOf((Class<Enum>) providerCls.asSubclass(Enum.class), "OPENSSL");
            builder = builderCls.getMethod("sslProvider", providerCls).invoke(builder, openSslProvider);
            Object insecure = insecureCls.getField("INSTANCE").get(null);
            builder = builderCls.getMethod("trustManager", javax.net.ssl.TrustManagerFactory.class)
                    .invoke(builder, insecure);
            Object ctx = builderCls.getMethod("build").invoke(builder);

            boolean isOpenSsl = ctx.getClass().getName().contains("OpenSsl");
            result(label, "C-tls", isOpenSsl && !ciphers.isEmpty(),
                    version + ", ciphers=" + ciphers.size() + ", ctx=" + ctx.getClass().getSimpleName());
        } catch (Throwable t) {
            result(label, "C-tls", false, rootMessage(t));
        }
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Walks to the deepest cause and returns its message. netty-tcnative's Library.java
     * concatenates one message per entry in NAMES, so the same musl error can appear twice
     * in a single UnsatisfiedLinkError -- that is one failure, not two.
     */
    private static String rootMessage(Throwable t) {
        if (t == null) {
            return "unavailable, no cause recorded";
        }
        Throwable root = t;
        while (root.getCause() != null && root.getCause() != root) {
            root = root.getCause();
        }
        return root.getClass().getSimpleName() + ": " + oneLine(root.getMessage());
    }

    private static String oneLine(String s) {
        return s == null ? "(no message)" : s.replaceAll("\\s+", " ").trim();
    }

    private static void result(String label, String level, boolean pass, String detail) {
        System.out.println("RESULT\t" + label + "\t" + level + "\t" + (pass ? "PASS" : "FAIL") + "\t" + detail);
    }
}
