import io.netty.buffer.ByteBufAllocator;
import io.netty.handler.ssl.OpenSsl;
import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;
import io.netty.handler.ssl.SslProvider;
import io.netty.handler.ssl.util.InsecureTrustManagerFactory;
import io.netty.handler.ssl.util.SelfSignedCertificate;

import javax.net.ssl.SSLEngine;
import javax.net.ssl.SSLEngineResult;
import javax.net.ssl.SSLSession;
import java.nio.ByteBuffer;

/**
 * Regression test: drives a COMPLETE TLS handshake through BoringSSL via netty-tcnative,
 * then sends application data both ways.
 *
 * Loading the library, or even constructing an SslContext, does not prove the crypto works.
 * This runs the real SSLEngine state machine in-memory (no sockets) with an OpenSSL-backed
 * server and client, so a library that loads but is subtly broken fails here.
 *
 * Compiled separately from AlpineNativeLoadTest because it imports netty directly, whereas
 * that class deliberately stays reflection-only so Level A needs no netty on the classpath.
 *
 * Emits:  RESULT <label> D-handshake PASS|FAIL <detail>
 */
public final class TlsHandshakeTest {

    private static final String PAYLOAD = "netty-tcnative on musl: the quick brown fox";

    public static void main(String[] args) {
        String label = args.length > 0 ? args[0] : "handshake";
        try {
            if (!OpenSsl.isAvailable()) {
                result(label, false, "OpenSsl unavailable: " + brief(OpenSsl.unavailabilityCause()));
                return;
            }
            SelfSignedCertificate cert = new SelfSignedCertificate();

            SslContext serverCtx = SslContextBuilder
                    .forServer(cert.certificate(), cert.privateKey())
                    .sslProvider(SslProvider.OPENSSL)
                    .build();
            SslContext clientCtx = SslContextBuilder
                    .forClient()
                    .sslProvider(SslProvider.OPENSSL)
                    .trustManager(InsecureTrustManagerFactory.INSTANCE)
                    .build();

            SSLEngine server = serverCtx.newEngine(ByteBufAllocator.DEFAULT);
            SSLEngine client = clientCtx.newEngine(ByteBufAllocator.DEFAULT);
            server.setUseClientMode(false);
            client.setUseClientMode(true);

            handshake(client, server);

            SSLSession session = client.getSession();
            String negotiated = session.getProtocol() + " / " + session.getCipherSuite();

            String c2s = roundTrip(client, server, PAYLOAD);
            String s2c = roundTrip(server, client, PAYLOAD);
            boolean dataOk = PAYLOAD.equals(c2s) && PAYLOAD.equals(s2c);

            result(label, dataOk, OpenSsl.versionString() + ", " + negotiated
                    + ", appdata=" + (dataOk ? "ok both ways" : "MISMATCH c2s=" + c2s + " s2c=" + s2c));
        } catch (Throwable t) {
            result(label, false, brief(t));
        }
    }

    /** Standard wrap/unwrap pump until both sides finish negotiating. */
    private static void handshake(SSLEngine client, SSLEngine server) throws Exception {
        client.beginHandshake();
        server.beginHandshake();

        int netSize = Math.max(client.getSession().getPacketBufferSize(),
                               server.getSession().getPacketBufferSize()) + 256;
        int appSize = Math.max(client.getSession().getApplicationBufferSize(),
                               server.getSession().getApplicationBufferSize()) + 256;

        ByteBuffer c2s = ByteBuffer.allocate(netSize);
        ByteBuffer s2c = ByteBuffer.allocate(netSize);
        ByteBuffer scratch = ByteBuffer.allocate(appSize);
        ByteBuffer empty = ByteBuffer.allocate(0);

        for (int guard = 0; guard < 200; guard++) {
            boolean progressed = false;
            progressed |= step(client, c2s, s2c, scratch, empty);
            progressed |= step(server, s2c, c2s, scratch, empty);

            // Under TLS 1.3 the client reaches NOT_HANDSHAKING while the server may still sit
            // in NEED_UNWRAP waiting for optional post-handshake traffic (e.g. session
            // tickets). Treat "wants to unwrap but nothing is queued" as settled; the
            // application-data round trip afterwards is what actually proves the handshake.
            boolean clientSettled = done(client) || idleUnwrap(client, s2c);
            boolean serverSettled = done(server) || idleUnwrap(server, c2s);
            if (clientSettled && serverSettled) {
                return;
            }
            if (!progressed) {
                throw new IllegalStateException("handshake stalled: client="
                        + client.getHandshakeStatus() + " server=" + server.getHandshakeStatus());
            }
        }
        throw new IllegalStateException("handshake did not converge");
    }

    private static boolean done(SSLEngine e) {
        SSLEngineResult.HandshakeStatus s = e.getHandshakeStatus();
        return s == SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING
                || s == SSLEngineResult.HandshakeStatus.FINISHED;
    }

    /** NEED_UNWRAP with an empty inbound buffer: nothing more is coming right now. */
    private static boolean idleUnwrap(SSLEngine e, ByteBuffer inbound) {
        SSLEngineResult.HandshakeStatus s = e.getHandshakeStatus();
        return (s == SSLEngineResult.HandshakeStatus.NEED_UNWRAP
                || s == SSLEngineResult.HandshakeStatus.NEED_UNWRAP_AGAIN)
                && inbound.position() == 0;
    }

    /** One wrap/unwrap/task move for a single engine. Returns true if anything happened. */
    private static boolean step(SSLEngine engine, ByteBuffer out, ByteBuffer in,
                                ByteBuffer scratch, ByteBuffer empty) throws Exception {
        boolean progressed = false;
        Runnable task;
        while ((task = engine.getDelegatedTask()) != null) {
            task.run();
            progressed = true;
        }
        switch (engine.getHandshakeStatus()) {
            case NEED_WRAP -> {
                SSLEngineResult r = engine.wrap(empty, out);
                progressed = r.bytesProduced() > 0 || r.getHandshakeStatus() != SSLEngineResult.HandshakeStatus.NEED_WRAP;
            }
            case NEED_UNWRAP, NEED_UNWRAP_AGAIN -> {
                in.flip();
                if (in.hasRemaining()) {
                    scratch.clear();
                    SSLEngineResult r = engine.unwrap(in, scratch);
                    progressed = r.bytesConsumed() > 0 || r.bytesProduced() > 0;
                }
                in.compact();
            }
            default -> { }
        }
        return progressed;
    }

    /**
     * Encrypts through {@code from}, decrypts in {@code to}, returns the recovered text.
     *
     * The unwrap side must loop: under TLS 1.3 the peer's first record after the handshake is
     * typically a NewSessionTicket, so a single unwrap legitimately produces zero application
     * bytes. Keep consuming records until application data appears.
     */
    private static String roundTrip(SSLEngine from, SSLEngine to, String text) throws Exception {
        ByteBuffer app = ByteBuffer.wrap(text.getBytes("UTF-8"));
        ByteBuffer net = ByteBuffer.allocate(from.getSession().getPacketBufferSize() + 256);
        while (app.hasRemaining()) {
            SSLEngineResult r = from.wrap(app, net);
            if (r.bytesConsumed() == 0 && r.bytesProduced() == 0) {
                break;
            }
        }
        net.flip();

        ByteBuffer plain = ByteBuffer.allocate(to.getSession().getApplicationBufferSize() + 256);
        while (net.hasRemaining()) {
            SSLEngineResult r = to.unwrap(net, plain);
            Runnable task;
            while ((task = to.getDelegatedTask()) != null) {
                task.run();
            }
            if (plain.position() > 0) {
                break;
            }
            if (r.bytesConsumed() == 0 && r.bytesProduced() == 0) {
                break;
            }
        }
        plain.flip();
        byte[] got = new byte[plain.remaining()];
        plain.get(got);
        return new String(got, "UTF-8");
    }

    private static String brief(Throwable t) {
        if (t == null) {
            return "(no cause)";
        }
        Throwable root = t;
        while (root.getCause() != null && root.getCause() != root) {
            root = root.getCause();
        }
        String m = root.getMessage();
        return root.getClass().getSimpleName() + ": " + (m == null ? "(no message)" : m.replaceAll("\\s+", " "));
    }

    private static void result(String label, boolean pass, String detail) {
        System.out.println("RESULT\t" + label + "\tD-handshake\t" + (pass ? "PASS" : "FAIL") + "\t" + detail);
    }
}
