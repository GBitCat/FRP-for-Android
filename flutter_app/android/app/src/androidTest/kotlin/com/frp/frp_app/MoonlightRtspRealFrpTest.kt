package com.frp.frp_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.CopyOnWriteArrayList

/** Optional isolated real-core fixture; never reads or modifies saved app settings. */
@RunWith(AndroidJUnit4::class)
class MoonlightRtspRealFrpTest {
    @Test
    fun updatedProviderReturnsEncryptedFrameAndEofWithoutApplicationForwarder() {
        val port = fixturePort()
        Socket(LOOPBACK, port).use { socket ->
            socket.soTimeout = 5_000
            val output = socket.getOutputStream()
            output.write(byteArrayOf(5, 1, 0))
            assertArrayEquals(byteArrayOf(5, 0), read(socket, 2))
            output.write(byteArrayOf(5, 1, 0, 1, 127, 0, 0, 1,
                (48010 shr 8).toByte(), 48010.toByte()))
            val reply = read(socket, 10)
            assertArrayEquals(byteArrayOf(5, 0, 0, 1), reply.copyOf(4))
            output.write(encryptedRequest())
            assertArrayEquals(encryptedResponse(), read(socket, encryptedResponse().size))
            assertEquals("The frp provider must propagate target EOF", -1, socket.getInputStream().read())
        }
    }

    @Test
    fun applicationPassesEncryptedResponseAndProviderEof() {
        exercise(encryptedRequest(), encryptedResponse())
    }

    @Test
    fun applicationPassesPlainOptionsAndProviderEof() {
        exercise(request("OPTIONS"), "RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".toByteArray())
    }

    @Test
    fun applicationPreservesLargeBodyBeforeEofWithSlowReader() {
        val body = ByteArray(256 * 1024) { it.toByte() }
        val response = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: ${body.size}\r\n\r\n".toByteArray() + body
        exercise(request("DESCRIBE"), response, slowReader = true)
    }

    private fun exercise(request: ByteArray, expected: ByteArray, slowReader: Boolean = false) {
        val port = fixturePort()
        val localPort = ServerSocket(0, 1, LOOPBACK).use { it.localPort }
        val logs = CopyOnWriteArrayList<String>()
        val context = Socks5LogContext("rtsp-fixture", "RTSP fixture", "rtsp-ports", "RTSP")
        val rule = Socks5ForwardRule("tcp", "127.0.0.1", localPort, "127.0.0.1", 48010,
            listOf(Socks5Upstream("fixture", "Updated frpc", "127.0.0.1", port, "", "")),
            logContext = context)
        Socks5Forwarder(listOf(rule), report = logs::add).use { forwarder ->
            forwarder.start()
            Socket(LOOPBACK, localPort).use { socket ->
                socket.soTimeout = 5_000
                socket.getOutputStream().write(request)
                if (slowReader) Thread.sleep(200)
                assertArrayEquals(expected, socket.getInputStream().readBytes())
            }
        }
        assertFalse("The application must not synthesize RTSP EOF",
            logs.mapNotNull { runCatching { JSONObject(it) }.getOrNull() }
                .any { it.optString("event") == "rtsp_eof_compat" })
    }

    private fun fixturePort(): Int {
        val value = InstrumentationRegistry.getArguments().getString("rtspSocksPort")?.toIntOrNull()
        assumeTrue("Requires an isolated updated-frp fixture via adb reverse", value != null && value in 1..65535)
        return value!!
    }

    private fun read(socket: Socket, count: Int): ByteArray {
        val result = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val n = socket.getInputStream().read(result, offset, count - offset)
            check(n > 0) { "Unexpected EOF" }
            offset += n
        }
        return result
    }

    private fun request(method: String) =
        "$method rtsp://127.0.0.1:48010 RTSP/1.0\r\nCSeq: 1\r\nX-GS-ClientVersion: 14\r\n\r\n".toByteArray()

    private fun encryptedRequest() = encryptedFrame(1, ByteArray(96) { (it + 1).toByte() })
    private fun encryptedResponse() = encryptedFrame(7, ByteArray(28) { it.toByte() })
    private fun encryptedFrame(sequence: Int, payload: ByteArray): ByteArray =
        ByteBuffer.allocate(24 + payload.size).putInt(Int.MIN_VALUE or payload.size).putInt(sequence)
            .put(ByteArray(16)).put(payload).array()

    companion object {
        private val LOOPBACK = InetAddress.getByName("127.0.0.1")
    }
}
