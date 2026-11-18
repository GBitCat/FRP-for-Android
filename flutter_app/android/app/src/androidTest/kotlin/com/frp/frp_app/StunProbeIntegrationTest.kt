package com.frp.frp_app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class StunProbeIntegrationTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun bridgePublishesProbeOutcomeAndWeightWithoutDumpingRawOutput() {
        assumeTrue(hasArm64Frpc())
        Fixture().use { first ->
            Fixture().use { second ->
                first.otherPort = second.port
                second.otherPort = first.port
                first.start()
                second.start()
                val logs = CopyOnWriteArrayList<String>()
                val finished = CountDownLatch(1)
                val response = AtomicReference<Any?>()
                StunProbeBridge(context, logs::add).use { bridge ->
                    bridge.probe(first.endpoint, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            response.set(result)
                            finished.countDown()
                        }
                        override fun error(code: String, message: String?, details: Any?) {
                            response.set(code)
                            finished.countDown()
                        }
                        override fun notImplemented() { finished.countDown() }
                    })
                    assertTrue(finished.await(12, TimeUnit.SECONDS))
                    assertEquals("reachable", (response.get() as Map<*, *>)["status"])
                    assertEquals(2, logs.size)
                    assertEquals("[STUN] Probing ${first.endpoint}", logs.first())
                    assertTrue(logs.last().contains("${first.endpoint}: reachable; weight=1;"))
                    assertTrue(logs.all { !it.contains('\n') && it.length < 200 })
                }
            }
        }
    }

    private fun withRunner(timeoutMillis: Long = 10_000, body: (StunProbeRunner, File) -> Unit) {
        val directory = File(context.cacheDir, "stun-test-${UUID.randomUUID()}")
        assertTrue(directory.mkdir())
        try {
            StunProbeRunner(
                File(context.applicationInfo.nativeLibraryDir, "libfrpc.so"),
                directory,
                timeoutMillis,
            ).use { runner -> body(runner, directory) }
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun rejectsNonNumericEndpointsWithoutRunningFrpcOrWritingConfig() {
        withRunner { runner, directory ->
            for (endpoint in listOf(null, "stun.example.com:3478", "127.0.0.1", "127.0.0.1:0", "127.0.0.1:65536", "256.0.0.1:3478", "127.00.0.1:3478", "[::1]:3478", "127.0.0.1:3478 --help")) {
                assertEquals(endpoint, "error", runner.run(endpoint).status)
                assertTrue(directory.listFiles().orEmpty().isEmpty())
            }
        }
    }

    @Test
    fun realFrpcProbeClassifiesLocalStunAndRemovesTemporaryConfig() {
        assumeTrue(hasArm64Frpc())
        Fixture().use { first ->
            Fixture().use { second ->
                first.otherPort = second.port
                second.otherPort = first.port
                first.start()
                second.start()
                withRunner { runner, directory ->
                    val result = runner.run(first.endpoint)
                    assertEquals(result.detail, "reachable", result.status)
                    assertEquals(0, result.exitCode)
                    assertEquals(1, first.requests.get())
                    assertEquals(1, second.requests.get())
                    assertTrue(result.detail.contains("STUN server: ${first.endpoint}"))
                    assertTrue(directory.listFiles().orEmpty().isEmpty())
                }
            }
        }
    }

    @Test
    fun realFrpcTimeoutGetsZeroWeightSignalWithoutPublicDns() {
        assumeTrue(hasArm64Frpc())
        Fixture(reply = false).use { silent ->
            silent.start()
            withRunner { runner, directory ->
                val start = System.nanoTime()
                val result = runner.run(silent.endpoint)
                val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
                assertEquals(result.detail, "timeout", result.status)
                assertEquals(1, result.exitCode)
                assertTrue(result.detail.contains("wait response from stun server timeout"))
                assertTrue("elapsed=$elapsed", elapsed in 2_500..9_000)
                assertTrue(silent.requests.get() > 0)
                assertTrue(directory.listFiles().orEmpty().isEmpty())
            }
        }
    }

    @Test
    fun deadlineTerminatesProbeAndCleansItsConfig() {
        assumeTrue(hasArm64Frpc())
        Fixture(reply = false).use { silent ->
            silent.start()
            withRunner(timeoutMillis = 400) { runner, directory ->
                val start = System.nanoTime()
                val result = runner.run(silent.endpoint)
                val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
                assertEquals(result.detail, "timeout", result.status)
                assertEquals(null, result.exitCode)
                assertTrue("elapsed=$elapsed", elapsed < 2_500)
                assertTrue(directory.listFiles().orEmpty().isEmpty())
            }
        }
    }

    @Test
    fun cancellingActiveProbeRejectsConcurrentWorkAndReclaimsProcess() {
        assumeTrue(hasArm64Frpc())
        Fixture(reply = false).use { silent ->
            silent.start()
            withRunner { runner, directory ->
                val result = AtomicReference<StunProbeResult>()
                val completed = CountDownLatch(1)
                val thread = Thread {
                    result.set(runner.run(silent.endpoint))
                    completed.countDown()
                }
                thread.start()
                try {
                    assertTrue(silent.firstRequest.await(3, TimeUnit.SECONDS))
                    assertEquals("error", runner.run(silent.endpoint).status)
                    runner.close()
                    assertTrue(completed.await(2, TimeUnit.SECONDS))
                    assertEquals("error", result.get().status)
                    assertTrue(result.get().detail.contains("cancelled"))
                    assertTrue(directory.listFiles().orEmpty().isEmpty())
                } finally {
                    runner.close()
                    thread.join(2_000)
                    assertFalse(thread.isAlive)
                }
            }
        }
    }

    private class Fixture(private val reply: Boolean = true) : AutoCloseable {
        private val socket = DatagramSocket(0, InetAddress.getByName("127.0.0.1"))
        private val stopped = AtomicBoolean(false)
        val requests = AtomicInteger()
        val firstRequest = CountDownLatch(1)
        val port: Int get() = socket.localPort
        val endpoint: String get() = "127.0.0.1:$port"
        var otherPort: Int = 0
        private val worker = Thread {
            socket.soTimeout = 100
            while (!stopped.get()) {
                try {
                    val packet = DatagramPacket(ByteArray(1024), 1024)
                    socket.receive(packet)
                    requests.incrementAndGet()
                    firstRequest.countDown()
                    if (!reply) continue
                    val attrs = ByteBuffer.allocate(24)
                    attrs.putShort(0x0001.toShort()).putShort(8).put(0).put(1)
                    attrs.putShort(40000.toShort()).put(byteArrayOf(198.toByte(), 51, 100, 10))
                    attrs.putShort(0x802c.toShort()).putShort(8).put(0).put(1)
                    attrs.putShort(otherPort.toShort()).put(byteArrayOf(127, 0, 0, 1))
                    val response = ByteBuffer.allocate(44)
                    response.putShort(0x0101.toShort()).putShort(24).putInt(0x2112a442)
                    response.put(packet.data, 8, 12).put(attrs.array())
                    socket.send(DatagramPacket(response.array(), 44, packet.socketAddress))
                } catch (_: SocketTimeoutException) {
                    // Allows prompt shutdown while no datagrams arrive.
                } catch (_: Exception) {
                    if (!stopped.get()) throw AssertionError("local STUN fixture failed")
                }
            }
        }.apply { isDaemon = true }

        fun start() = worker.start()

        override fun close() {
            stopped.set(true)
            socket.close()
            if (worker.isAlive) worker.join(1_000)
        }
    }
}
