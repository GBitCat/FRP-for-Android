package com.frp.frp_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** RTSP traffic remains opaque: only the upstream socket determines response EOF. */
@RunWith(AndroidJUnit4::class)
class MoonlightRtspForwarderIntegrationTest {
    @Test
    fun optionsPropagatesUpstreamEofInBothModesWithoutSyntheticEofOrPayloadLogs() {
        val request = request("OPTIONS", extra = "Host: request-marker-never-log\r\n")
        val response = ascii("RTSP/1.0 200 OK\r\nCSeq: 1\r\nX-Test: response-marker-never-log\r\n\r\n")
        for (mode in listOf("onDemand", "immediate")) {
            Fixture(request, listOf(response), sendEof = true).use { fixture ->
                val events = CopyOnWriteArrayList<String>()
                val rule = rule(fixture.port, mode = mode)
                Socks5Forwarder(listOf(rule), events::add, handshakeTimeoutMs = 3_000).use { forwarder ->
                    forwarder.start()
                    if (mode == "immediate") {
                        assertTrue("Immediate SOCKS channel did not become ready", waitUntil {
                            records(events).any { it.optString("event") == "warm_ready" }
                        })
                    }
                    client(rule.listenPort).use { socket ->
                        socket.getOutputStream().write(request)
                        assertArrayEquals(response, readExact(socket.getInputStream(), response.size))
                        assertEquals("Moonlight must receive EOF while its request side stays open", -1,
                            socket.getInputStream().read())
                        assertFalse("A response EOF must not close the request direction",
                            fixture.clientClosed.await(150, TimeUnit.MILLISECONDS))
                        socket.shutdownOutput()
                        assertTrue("Client EOF was not forwarded upstream",
                            fixture.clientClosed.await(3, TimeUnit.SECONDS))
                    }
                    assertTrue(compatEvents(events).isEmpty())
                    assertFalse(events.any { it.contains("request-marker-never-log") })
                    assertFalse(events.any { it.contains("response-marker-never-log") })
                    fixture.assertHealthy()
                }
            }
        }
    }

    @Test
    fun fragmentedDescribeWithLengthPreservesLargeBodyBeforeEof() {
        val request = request("DESCRIBE")
        val body = ByteArray(65_549) { (it % 251).toByte() }
        val header = ascii("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: ${body.size}\r\n\r\n")
        val response = header + body
        val fragments = listOf(header.copyOfRange(0, 7), header.copyOfRange(7, header.size)) +
            body.toList().chunked(4_096).map { it.toByteArray() }
        Fixture(request, fragments, gapMs = 4, sendEof = true).use { fixture ->
            withForwarder(fixture) { rule, events ->
                client(rule.listenPort).use { socket ->
                    writeFragmented(socket, request, 7)
                    assertArrayEquals(response, readExact(socket.getInputStream(), response.size))
                    assertEquals(-1, socket.getInputStream().read())
                }
                assertTrue(compatEvents(events).isEmpty())
                fixture.assertHealthy()
            }
        }
    }

    @Test
    fun encryptedFramePreservesBytesAndPropagatesUpstreamEof() {
        val request = encryptedFrame(ByteArray(96) { (it + 13).toByte() })
        val response = encryptedFrame(ByteArray(28) { (it + 71).toByte() })
        val fragments = listOf(response.copyOfRange(0, 3), response.copyOfRange(3, 21),
            response.copyOfRange(21, 33), response.copyOfRange(33, response.size))
        Fixture(request, fragments, gapMs = 10, sendEof = true).use { fixture ->
            withForwarder(fixture) { rule, events ->
                client(rule.listenPort).use { socket ->
                    writeFragmented(socket, request, 9)
                    assertArrayEquals(response, readExact(socket.getInputStream(), response.size))
                    assertEquals(-1, socket.getInputStream().read())
                }
                assertTrue(compatEvents(events).isEmpty())
                fixture.assertHealthy()
            }
        }
    }

    @Test
    fun completeMoonlightResponsesDoNotInventEofWhileUpstreamRemainsOpen() {
        assertBypassed(request("OPTIONS"), ascii("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n"))
        assertBypassed(encryptedFrame(ByteArray(96) { it.toByte() }),
            encryptedFrame(ByteArray(28) { (it + 1).toByte() }))
    }

    @Test
    fun describeWithoutLengthDoesNotCutOffLaterSdpOrInventEof() {
        val request = request("DESCRIBE")
        val header = ascii("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n")
        val sdp = ascii("v=0\r\ns=Sunshine\r\nm=video 47998 RTP/AVP 96\r\n")
        // Sunshine can send a successful plaintext DESCRIBE without a length.
        // Waiting after the header exposes an incorrect zero-body assumption.
        Fixture(request, listOf(header, sdp), gapMs = 80).use { fixture ->
            withForwarder(fixture) { rule, events ->
                client(rule.listenPort).use { socket ->
                    socket.getOutputStream().write(request)
                    assertArrayEquals(header + sdp, readExact(socket.getInputStream(), header.size + sdp.size))
                    assertStillOpen(socket)
                }
                assertTrue(compatEvents(events).isEmpty())
                fixture.assertHealthy()
            }
        }
    }

    @Test
    fun incompleteEncryptedResponseDoesNotInventEof() {
        val request = encryptedFrame(ByteArray(96) { it.toByte() })
        val complete = encryptedFrame(ByteArray(28) { (it + 1).toByte() })
        val partial = complete.copyOf(complete.size - 3)
        assertBypassed(request, partial)
    }

    @Test
    fun duplicateContentLengthIsPassedThroughWithoutSyntheticEof() {
        val response = ascii("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n")
        assertBypassed(request("OPTIONS"), response)
    }

    @Test
    fun ordinaryTcpTrafficOnRtspPortKeepsItsOriginalLifetime() {
        assertBypassed(ascii("ordinary request"), ascii("ordinary response"))
    }

    @Test
    fun rtspWithoutMoonlightRequestMarkerKeepsItsOriginalLifetime() {
        val request = ascii("OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n")
        val response = ascii("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n")
        assertBypassed(request, response)
    }

    @Test
    fun otherTargetPortsDoNotApplyRtspCompatibility() {
        val response = ascii("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n")
        assertBypassed(request("OPTIONS"), response, targetPort = 48011)
    }

    private fun assertBypassed(request: ByteArray, response: ByteArray, targetPort: Int = 48010) {
        Fixture(request, listOf(response)).use { fixture ->
            withForwarder(fixture, targetPort) { rule, events ->
                client(rule.listenPort).use { socket ->
                    socket.getOutputStream().write(request)
                    assertArrayEquals(response, readExact(socket.getInputStream(), response.size))
                    assertStillOpen(socket)
                }
                assertTrue(compatEvents(events).isEmpty())
                fixture.assertHealthy()
            }
        }
    }

    private fun withForwarder(fixture: Fixture, targetPort: Int = 48010,
        test: (Socks5ForwardRule, CopyOnWriteArrayList<String>) -> Unit) {
        val events = CopyOnWriteArrayList<String>()
        val rule = rule(fixture.port, targetPort = targetPort)
        Socks5Forwarder(listOf(rule), events::add, handshakeTimeoutMs = 3_000).use { forwarder ->
            forwarder.start()
            test(rule, events)
        }
    }

    private fun rule(upstreamPort: Int, targetPort: Int = 48010, mode: String = "onDemand") =
        Socks5ForwardRule("tcp", "127.0.0.1", freePort(), "127.0.0.1", targetPort,
            listOf(Socks5Upstream("rtsp-visitor", "RTSP visitor", "127.0.0.1", upstreamPort, "", "")),
            mode, CONTEXT)

    private fun client(port: Int) = Socket(LOOPBACK, port).apply { soTimeout = 3_000 }

    private fun assertStillOpen(socket: Socket) {
        socket.soTimeout = 250
        try {
            val next = socket.getInputStream().read()
            throw AssertionError("Expected connection to remain open, got $next")
        } catch (_: SocketTimeoutException) {
            // No EOF is expected: the endpoint intentionally remains open.
        }
    }

    private fun writeFragmented(socket: Socket, bytes: ByteArray, size: Int) {
        var offset = 0
        while (offset < bytes.size) {
            val count = minOf(size, bytes.size - offset)
            socket.getOutputStream().write(bytes, offset, count)
            socket.getOutputStream().flush()
            offset += count
            if (offset < bytes.size) Thread.sleep(2)
        }
    }

    private fun records(events: List<String>) = events.map { JSONObject(it) }
    private fun compatEvents(events: List<String>) = records(events).filter { it.optString("event") == "rtsp_eof_compat" }

    private class Fixture(
        private val expectedRequest: ByteArray,
        private val responseParts: List<ByteArray>,
        private val gapMs: Long = 0,
        private val sendEof: Boolean = false,
    ) : Closeable {
        private val server = ServerSocket(0, 8, LOOPBACK)
        private val closed = AtomicBoolean(false)
        private val sockets = ConcurrentHashMap<Socket, Boolean>()
        private val failures = CopyOnWriteArrayList<Throwable>()
        private val workers = CopyOnWriteArrayList<Thread>()
        val clientClosed = CountDownLatch(1)
        val port: Int get() = server.localPort
        private val acceptThread = Thread({
            while (!closed.get()) {
                val socket = try { server.accept() } catch (_: IOException) { break }
                sockets[socket] = true
                val worker = Thread({
                    try {
                        handle(socket)
                    } catch (error: Throwable) {
                        // Closing a prewarmed unused channel is expected. Tests
                        // independently fail if a business response is missing.
                        if (!closed.get() && error !is IOException) failures.add(error)
                    } finally {
                        runCatching { socket.close() }
                        sockets.remove(socket)
                    }
                }, "rtsp-fixture-client").apply { isDaemon = true }
                workers.add(worker)
                worker.start()
            }
        }, "rtsp-fixture-accept").apply { isDaemon = true; start() }

        private fun handle(socket: Socket) {
            socket.soTimeout = 5_000
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            val greeting = readExact(input, 2)
            check(greeting[0] == 5.toByte())
            val methods = readExact(input, greeting[1].toInt() and 255)
            check(0.toByte() in methods)
            output.write(byteArrayOf(5, 0))
            val connect = readExact(input, 4)
            check(connect[0] == 5.toByte() && connect[1] == 1.toByte())
            val addressSize = when (connect[3].toInt()) {
                1 -> 4
                4 -> 16
                else -> throw AssertionError("Unexpected SOCKS address type")
            }
            readExact(input, addressSize + 2)
            output.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 1))
            check(expectedRequest.contentEquals(readExact(input, expectedRequest.size))) {
                "Business request changed in transit"
            }
            for ((index, part) in responseParts.withIndex()) {
                output.write(part)
                output.flush()
                if (index != responseParts.lastIndex && gapMs > 0) Thread.sleep(gapMs)
            }
            // Tests explicitly control EOF independently of protocol framing.
            if (sendEof) socket.shutdownOutput()
            socket.soTimeout = 0
            while (input.read() >= 0) { }
            clientClosed.countDown()
        }

        fun assertHealthy() {
            if (failures.isNotEmpty()) throw AssertionError("SOCKS fixture failed", failures.first())
        }

        override fun close() {
            closed.set(true)
            runCatching { server.close() }
            sockets.keys.forEach { runCatching { it.close() } }
            acceptThread.join(1_000)
            workers.forEach { it.join(1_000) }
            assertHealthy()
        }
    }

    companion object {
        private val LOOPBACK = InetAddress.getByName("127.0.0.1")
        private val CONTEXT = Socks5LogContext("RTSPTEST/group/1", "RTSP test", "moonlight", "Moonlight")

        private fun ascii(text: String) = text.toByteArray(Charsets.US_ASCII)
        private fun request(method: String, extra: String = "") =
            ascii("$method * RTSP/1.0\r\nCSeq: 1\r\nX-GS-ClientVersion: 14\r\n$extra\r\n")

        private fun encryptedFrame(payload: ByteArray): ByteArray = ByteBuffer.allocate(24 + payload.size)
            .putInt(Int.MIN_VALUE or payload.size).putInt(1)
            .put(ByteArray(16) { (it + 1).toByte() }).put(payload).array()

        private fun freePort() = ServerSocket(0, 1, LOOPBACK).use { it.localPort }

        private fun readExact(input: InputStream, count: Int): ByteArray {
            val bytes = ByteArray(count)
            var offset = 0
            while (offset < count) {
                val read = input.read(bytes, offset, count - offset)
                if (read < 0) throw EOFException("Expected $count bytes, received $offset")
                offset += read
            }
            return bytes
        }

        private fun waitUntil(condition: () -> Boolean): Boolean {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(4)
            while (System.nanoTime() < deadline) {
                if (condition()) return true
                Thread.sleep(20)
            }
            return condition()
        }
    }
}
