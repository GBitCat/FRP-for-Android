package com.frp.frp_app

import android.content.Context
import androidx.test.filters.SdkSuppress
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.DataInputStream
import java.io.File
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Set endpointAuthFrpsPort to a loopback, token-free test frps forwarded by adb. */
@RunWith(AndroidJUnit4::class)
class FrpcEndpointAuthIntegrationTest {
    /** Uses real, password-protected provider plugins and a loopback echo service
     * on the fixture host. No application configuration store is modified. */
    @Test
    fun serviceStartsAuthenticatedTcpAndUdpRoutes() {
        val serverPort = InstrumentationRegistry.getArguments().getString("endpointEchoFrpsPort")?.toIntOrNull()
        assumeTrue("Requires the isolated authenticated TCP/UDP echo fixture",
            hasArm64Frpc() && serverPort != null && serverPort in 1..65535)
        val context: Context = ApplicationProvider.getApplicationContext()
        val loopback = InetAddress.getByName("127.0.0.1")
        val sockets = List(3) { ServerSocket(0, 1, loopback) }
        val ports = sockets.map { it.localPort }
        val udpPort = DatagramSocket(0, loopback).use { it.localPort }
        sockets.forEach { it.close() }
        val toml = """
            serverAddr = "127.0.0.1"
            serverPort = $serverPort
            transport.wireProtocol = "v2"
            [[visitors]]
            name = "app-echo-tcp"
            type = "stcp"
            serverName = "audit-echo-stcp"
            secretKey = "audit-fixture"
            bindAddr = "127.0.0.1"
            bindPort = ${ports[0]}
            [[visitors]]
            name = "app-echo-udp"
            type = "sudp"
            serverName = "audit-echo-sudp"
            secretKey = "audit-fixture"
            bindPort = -1
            [visitors.plugin]
            type = "socks5_udp"
            bindAddr = "127.0.0.1"
            bindPort = ${ports[1]}
        """.trimIndent()
        val forwards = listOf("tcp", "udp").mapIndexed { index, protocol ->
            val name = "app-echo-$protocol"
            mapOf(
                "protocol" to protocol, "bindAddress" to "127.0.0.1",
                "listenPort" to if (protocol == "tcp") ports[2] else udpPort,
                "targetIp" to "127.0.0.1", "targetPort" to 27981, "mode" to "onDemand",
                "upstreams" to listOf(mapOf("id" to name, "name" to name, "host" to "127.0.0.1",
                    "port" to ports[index], "username" to "test-user", "password" to "test-password")),
            )
        }
        fun waitFor(description: String, work: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
            var last: IOException? = null
            do {
                try { if (work()) return } catch (e: IOException) { last = e }
                Thread.sleep(75)
            } while (System.nanoTime() < deadline)
            throw AssertionError("Timed out waiting for $description", last)
        }
        fun echo(phase: String) {
            // Verify exact payload bytes, including zero bytes and non-ASCII values.
            val payload = ByteArray(512) { (it * 7).toByte() } + phase.toByteArray()
            waitFor("$phase authenticated TCP echo") {
                Socket().use {
                    it.connect(InetSocketAddress(loopback, ports[2]), 500)
                    it.soTimeout = 2_500
                    it.getOutputStream().write(payload)
                    val reply = ByteArray(payload.size)
                    DataInputStream(it.getInputStream()).readFully(reply)
                    assertArrayEquals(payload, reply)
                }
                true
            }
            waitFor("$phase authenticated UDP echo") {
                DatagramSocket(0, loopback).use {
                    it.soTimeout = 2_500
                    it.send(DatagramPacket(payload, payload.size, loopback, udpPort))
                    val reply = DatagramPacket(ByteArray(2048), 2048)
                    it.receive(reply)
                    assertArrayEquals(payload, reply.data.copyOf(reply.length))
                }
                true
            }
        }
        val prefs = context.getSharedPreferences("frp_state", Context.MODE_PRIVATE)
        try {
            FrpcService.stop(context)
            waitFor("prior test service to stop") { FrpcService.instance == null }
            assertTrue(FrpcService.start(context, toml, forwards))
            echo("initial")
            // Restore the v1 envelope used by earlier betas, which had neither
            // a mode field nor logContext. Endpoint keys must be freshly provisioned.
            val saved = JSONObject(SecureStringCodec.decrypt(prefs.getString("last_config_payload", null)!!))
            val array = saved.getJSONArray("socks5Forwards")
            repeat(array.length()) { array.getJSONObject(it).remove("mode") }
            val legacy = SecureStringCodec.encrypt(saved.toString())
            assertTrue(FrpcService.stop(context))
            waitFor("test service to stop before recovery") { FrpcService.instance == null }
            assertTrue(prefs.edit().putBoolean("was_running", true).remove("pending_start_id")
                .putString("last_config_payload", legacy).commit())
            FrpcService.ensureRunning(context)
            echo("restored")
        } finally {
            FrpcService.stop(context)
            waitFor("test service cleanup") { FrpcService.instance == null }
        }
    }

    @Test
    @SdkSuppress(minSdkVersion = 26)
    fun embeddedChildProvesTheIdentityAndFrameLimitOfEachManagedVisitor() {
        val serverPort = InstrumentationRegistry.getArguments().getString("endpointAuthFrpsPort")?.toIntOrNull()
        assumeTrue("Requires ARM64 and a local frps fixture",
            hasArm64Frpc() && serverPort != null && serverPort in 1..65535)
        val context: Context = ApplicationProvider.getApplicationContext()
        val root = File(context.cacheDir, "endpoint-proof-${UUID.randomUUID()}")
        assertTrue(root.mkdir())
        val loopback = InetAddress.getByName("127.0.0.1")
        val listeners = List(4) { ServerSocket(0, 1, loopback) }
        val ports = listeners.map { it.localPort }
        val protocols = listOf("stcp", "xtcp", "sudp", "xudp")
        val config = File(root, "fixture.toml")
        config.writeText(buildString {
            appendLine("serverAddr = \"127.0.0.1\"")
            appendLine("serverPort = $serverPort")
            appendLine("natHoleStunServer = \"127.0.0.1:9\"")
            appendLine("transport.wireProtocol = \"v2\"")
            appendLine("log.disablePrintColor = true")
            for ((index, type) in protocols.withIndex()) {
                appendLine("[[visitors]]")
                appendLine("name = \"local-$type\"")
                appendLine("type = \"$type\"")
                appendLine("serverName = \"unused-fixture-provider-$type\"")
                appendLine("secretKey = \"fixture-only\"")
                appendLine("bindAddr = \"127.0.0.1\"")
                val udp = type.endsWith("udp")
                appendLine("bindPort = ${if (udp) -1 else ports[index]}")
                if (udp) {
                    appendLine("[visitors.plugin]")
                    appendLine("type = \"socks5_udp\"")
                    appendLine("bindAddr = \"127.0.0.1\"")
                    appendLine("bindPort = ${ports[index]}")
                }
            }
        })
        val routes = protocols.mapIndexed { index, type ->
            val upstream = Socks5Upstream("id-$type", "local-$type", "127.0.0.1", ports[index], "", "")
            Socks5ForwardRule(if (type.endsWith("udp")) "udp" else "tcp", "127.0.0.1", 5510 + index,
                "127.0.0.1", 5510 + index, listOf(upstream))
        }
        val auth = FrpcEndpointAuth()
        val builder = ProcessBuilder(File(context.applicationInfo.nativeLibraryDir, "libfrpc.so").absolutePath,
            "-c", config.absolutePath).directory(root).redirectErrorStream(true)
        val output = File(root, "frpc.log")
        // ProcessBuilder.redirectOutput(File) is available starting at API 26.
        builder.redirectOutput(output)
        var child: Process? = null
        try {
            listeners.forEach { it.close() }
            child = auth.start(builder, routes)
            val deadline = System.nanoTime() + 12_000_000_000L
            for ((index, type) in protocols.withIndex()) {
                var socket: Socket
                while (true) {
                    try { socket = Socket(loopback, ports[index]); break } catch (e: IOException) {
                        if (System.nanoTime() >= deadline) throw AssertionError("frpc did not bind $type: ${output.readText().takeLast(2500)}", e)
                        Thread.sleep(50)
                    }
                }
                val limit = socket.use {
                    it.soTimeout = 2_000
                    auth.verify(it, "local-$type", DataInputStream(it.getInputStream()))
                }
                assertEquals("Negotiated core limit on $type", when (type) {
                    "sudp" -> 1500 - 83
                    "xudp" -> 1150 - 11 - 83
                    else -> 0
                }, limit)
                Socket(loopback, ports[index]).use {
                    it.soTimeout = 2_000
                    assertThrows(IOException::class.java) {
                        auth.verify(it, "different-visitor", DataInputStream(it.getInputStream()))
                    }
                }
            }
        } finally {
            listeners.forEach { it.close() }
            child?.destroy()
            if (child?.waitFor(2, TimeUnit.SECONDS) == false) {
                child.destroyForcibly()
                child.waitFor(2, TimeUnit.SECONDS)
            }
            root.deleteRecursively()
        }
    }
}
