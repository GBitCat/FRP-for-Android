package com.frp.frp_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.Closeable
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class Socks5ForwarderIntegrationTest {
    @Test
    fun runtimeEnvelopeSizeLeavesBinderHeadroomWithoutChangingLegacyLimit() {
        // Exercise the pure admission check; never schedule a service or mutate
        // the existing encrypted run intent on the test device.
        val forwards = listOf(rule("udp", 5513, upstream(40000)))
        val overhead = FrpcRuntimePayload("", forwards).encode().toByteArray(Charsets.UTF_8).size
        val available = FrpcService.MAX_SOCKS_RUNTIME_PAYLOAD_BYTES - overhead
        val asciiLimit = FrpcRuntimePayload("x".repeat(available), forwards).encode()
        assertEquals(384 * 1024, asciiLimit.toByteArray(Charsets.UTF_8).size)
        assertTrue(FrpcService.runtimePayloadFits(asciiLimit))
        assertFalse(FrpcService.runtimePayloadFits(
            FrpcRuntimePayload("x".repeat(available + 1), forwards).encode()))
        val unicode = "界".repeat(available / 3) + "x".repeat(available % 3)
        assertTrue(FrpcService.runtimePayloadFits(FrpcRuntimePayload(unicode, forwards).encode()))
        assertFalse(FrpcService.runtimePayloadFits(FrpcRuntimePayload(unicode + "x", forwards).encode()))
        val legacy = "#" + "x".repeat(512 * 1024 - 1)
        assertTrue(FrpcService.runtimePayloadFits(legacy))
        assertFalse(FrpcService.runtimePayloadFits(legacy + "x"))
    }

    @Test
    fun encryptedRecoveryEnvelopePreservesForwardsAndReadsLegacyConfig() {
        val toml = "serverAddr = \"127.0.0.1\"\nserverPort = 7000\n"
        val rule = rule("udp", freeUdpPort(), upstream(1080, "alice", "local-secret"))
            .copy(mode = "immediate", logContext = context("encrypted"))
        val payload = FrpcRuntimePayload(toml, listOf(rule))
        val encrypted = SecureStringCodec.encrypt(payload.encode())
        assertFalse(encrypted.contains("local-secret"))
        assertEquals(payload, FrpcRuntimePayload.decode(SecureStringCodec.decrypt(encrypted)))
        assertEquals(toml, FrpcRuntimePayload(toml).encode())
        assertEquals(FrpcRuntimePayload(toml), FrpcRuntimePayload.decode(toml))
        assertFalse(payload.configContent.contains("local-secret"))
        assertThrows(Exception::class.java) {
            FrpcRuntimePayload.decode("""{"androidRuntimeVersion":99,"configContent":"x","socks5Forwards":[]}""")
        }
    }

    @Test
    fun rejectsNonLocalUpstreamsAndInvalidForwardingPorts() {
        val base = rule("tcp", freeTcpPort(), upstream(1080)).toJson()
        base.getJSONArray("upstreams").getJSONObject(0).put("host", "203.0.113.10")
        assertThrows(Exception::class.java) { Socks5ForwardRule.fromJsonArray(JSONArray().put(base)) }
        val invalidPort = rule("tcp", freeTcpPort(), upstream(1080)).toJson().put("listenPort", 65_536)
        assertThrows(Exception::class.java) { Socks5ForwardRule.fromJsonArray(JSONArray().put(invalidPort)) }
        val duplicate = rule("tcp", freeTcpPort(), upstream(1080)).toJson()
        assertThrows(Exception::class.java) {
            Socks5ForwardRule.fromJsonArray(JSONArray().put(duplicate).put(duplicate))
        }
    }

    @Test
    fun connectionModeDefaultsToOnDemandAndRejectsUnknownValues() {
        val original = rule("tcp", freeTcpPort(), upstream(1080)).toJson()
        original.remove("mode")
        assertEquals("onDemand", Socks5ForwardRule.fromJsonArray(JSONArray().put(original)).single().mode)
        for (invalid in listOf<Any>("always", "", false, 1, org.json.JSONObject.NULL)) {
            original.put("mode", invalid)
            assertThrows(Exception::class.java) { Socks5ForwardRule.fromJsonArray(JSONArray().put(original)) }
        }
        val immediate = rule("udp", freeUdpPort(), upstream(1080)).copy(mode = "immediate")
        val envelope = FrpcRuntimePayload("serverAddr = \"127.0.0.1\"", listOf(immediate))
        assertEquals(envelope, FrpcRuntimePayload.decode(envelope.encode()))
    }

    @Test
    fun logContextRoundTripsWithoutChangingLegacyPayloadAndRejectsInvalidFields() {
        val legacy = rule("udp", freeUdpPort(), upstream(1080))
        assertFalse(legacy.toJson().has("logContext"))
        assertEquals(legacy, Socks5ForwardRule.fromJsonArray(JSONArray().put(legacy.toJson())).single())
        val contextual = legacy.copy(logContext = context("video"))
        val envelope = FrpcRuntimePayload("serverAddr = \"127.0.0.1\"", listOf(contextual))
        assertEquals(envelope, FrpcRuntimePayload.decode(envelope.encode()))
        // Older imported connection IDs admitted C1 characters. Identity must
        // survive recovery unchanged even though display names reject them.
        val imported = contextual.copy(logContext = context("imported").copy(connectionId = "old\u0085identifier"))
        assertEquals(imported, Socks5ForwardRule.fromJsonArray(JSONArray().put(imported.toJson())).single())
        val invalidContexts = listOf<Any>(
            JSONObject.NULL, "invalid", 1,
            context("x").toJson().put("configName", false),
            context("x").toJson().put("connectionId", ""),
            context("x").toJson().put("configKey", "x".repeat(129)),
            context("x").toJson().put("connectionName", "x".repeat(161)),
            context("x").toJson().put("connectionName", "line\nbreak"),
            context("x").toJson().put("connectionName", "control\u0085"),
            context("x").toJson().put("unexpected", "value"),
            context("x").toJson().also { it.remove("configName") },
        )
        for (invalid in invalidContexts) assertThrows(Exception::class.java) {
            Socks5ForwardRule.fromJsonArray(JSONArray().put(legacy.toJson().put("logContext", invalid)))
        }
    }

    @Test
    fun maximumStructuredTrafficFitsLogRingWithoutTruncatingIdentityOrCounters() {
        val identity = Socks5LogContext("\u0085".repeat(128), "\u2028".repeat(160),
            "\u0086".repeat(128), "\\".repeat(160))
        val route = rule("udp", 5513, upstream(1080)).copy(logContext = identity)
        val maximum = Long.MAX_VALUE
        val statistics = Socks5TrafficStats.Snapshot(
            1, LongArray(4) { maximum }, LongArray(4) { maximum }, maximum, maximum,
            maximum, maximum, 65_507, 65_507, 65_507, 65_507, maximum, maximum,
            LongArray(Socks5Drop.entries.size) { maximum }, LongArray(Socks5Drop.entries.size) { maximum },
        ).json("udp").put("final", true)
        val text = Socks5LogFormatter.line(route, "traffic", "long statistics description ".repeat(40), statistics)
        assertTrue(text.length + "[2000-01-01 00:00:00] [SOCKS5] ".length < 4096)
        val decoded = JSONObject(text)
        assertEquals(identity.configKey, decoded.getString("configKey"))
        assertEquals(identity.connectionId, decoded.getString("connectionId"))
        assertTrue(decoded.getString("configName").isNotEmpty())
        assertTrue(decoded.getString("connectionName").isNotEmpty())
        assertEquals(maximum, decoded.getLong("udpFrpcTxBytes"))
        assertEquals(maximum, decoded.getLong("udpLocalTxPackets"))
        assertEquals(Socks5Drop.entries.size, decoded.getJSONObject("drops").length())
        for (reason in Socks5Drop.entries) {
            assertEquals(maximum, decoded.getJSONObject("drops").getJSONObject(reason.field).getLong("packets"))
            assertEquals(maximum, decoded.getJSONObject("drops").getJSONObject(reason.field).getLong("bytes"))
        }
    }

    @Test
    fun structuredTcpLogsKeepPortIdentitiesAndCountOnlyWrittenBusinessBytes() {
        SocksFixture(username = "account-never-log", password = "password-never-log", streamingTcp = true).use { fixture ->
            val events = CopyOnWriteArrayList<String>()
            val ports = listOf(freeTcpPort(), freeTcpPort())
            val routes = ports.mapIndexed { index, port ->
                rule("tcp", port, upstream(fixture.port, "account-never-log", "password-never-log"))
                    .copy(mode = "immediate", logContext = context("tcp-$index"))
            }
            val forwarder = Socks5Forwarder(routes, report = events::add, handshakeTimeoutMs = 3_000)
            try {
                forwarder.start()
                assertTrue(waitUntil { records(events).count { it.getString("event") == "warm_ready" } == 2 })
                assertTrue(records(events).none { it.getString("event") == "traffic" })
                for (port in ports) for (message in listOf("first request", "second longer request")) {
                    assertEquals(message, tcpRequest(port, message))
                }
            } finally { forwarder.close() }
            assertTrue(waitUntil { ports.all { finalTraffic(events, it) != null } })
            val expectedBytes = ("first request".length + "second longer request".length).toLong()
            for ((index, port) in ports.withIndex()) {
                val traffic = finalTraffic(events, port)!!
                assertEquals("config-tcp-$index", traffic.getString("configKey"))
                assertEquals("connection-tcp-$index", traffic.getString("connectionId"))
                assertEquals("tcp", traffic.getString("protocol"))
                assertEquals(expectedBytes, traffic.getLong("tcpFrpcTxBytes"))
                assertEquals(expectedBytes, traffic.getLong("tcpLocalTxBytes"))
                assertFalse(traffic.has("tcpPackets"))
                assertFalse(traffic.has("udpLocalRxPackets"))
                assertTrue(traffic.getLong("lastTxAtMs") > 0)
                assertTrue(traffic.getLong("lastRxAtMs") > 0)
            }
            assertTrue(events.all { it.length + "[SOCKS5] ".length < 4096 })
            assertFalse(events.joinToString().contains("account-never-log"))
            assertFalse(events.joinToString().contains("password-never-log"))
        }
    }

    @Test
    fun structuredUdpLogsCountEveryStageAndMalformedRepliesWithoutMixingPorts() {
        SocksFixture(fragmentedReplyFirst = true, malformedReplyFirst = true).use { fixture ->
            val events = CopyOnWriteArrayList<String>()
            val firstPort = freeUdpPort()
            val secondPort = freeUdpPort()
            val routes = listOf(
                rule("udp", firstPort, upstream(fixture.port)).copy(logContext = context("video")),
                rule("udp", secondPort, upstream(fixture.port)).copy(logContext = context("audio")),
            )
            val forwarder = Socks5Forwarder(routes, report = events::add, handshakeTimeoutMs = 3_000)
            try {
                forwarder.start()
                DatagramSocket(0, LOOPBACK).use { first ->
                    DatagramSocket(0, LOOPBACK).use { second ->
                        assertTrue(udpRequest(first, firstPort, "first").endsWith(":first"))
                        assertTrue(udpRequest(second, firstPort, "second").endsWith(":second"))
                        assertTrue(udpRequest(first, firstPort, "again").endsWith(":again"))
                        assertTrue(udpRequest(first, secondPort, "other").endsWith(":other"))
                    }
                }
            } finally { forwarder.close() }
            assertTrue(waitUntil { finalTraffic(events, firstPort) != null && finalTraffic(events, secondPort) != null })
            val first = finalTraffic(events, firstPort)!!
            val second = finalTraffic(events, secondPort)!!
            assertEquals("connection-video", first.getString("connectionId"))
            assertEquals("connection-audio", second.getString("connectionId"))
            assertEquals(3L, first.getLong("udpLocalRxPackets"))
            assertEquals(16L, first.getLong("udpLocalRxBytes"))
            assertEquals(3L, first.getLong("udpFrpcTxPackets"))
            assertEquals(46L, first.getLong("udpFrpcTxBytes"))
            assertEquals(16L, first.getLong("udpFrpcTxPayloadBytes"))
            assertEquals(9L, first.getLong("udpFrpcRxPackets"))
            assertEquals(116L, first.getLong("udpFrpcRxBytes")) // valid + fragment + malformed 4-byte frames
            assertEquals(22L, first.getLong("udpFrpcRxPayloadBytes"))
            assertEquals(3L, first.getLong("udpLocalTxPackets"))
            assertEquals(22L, first.getLong("udpLocalTxBytes"))
            assertEquals(5, first.getInt("udpTxMinBytes"))
            assertEquals(6, first.getInt("udpTxMaxBytes"))
            assertEquals(7, first.getInt("udpRxMinBytes"))
            assertEquals(8, first.getInt("udpRxMaxBytes"))
            assertEquals(3L, first.getJSONObject("drops").getJSONObject("fragmented").getLong("packets"))
            assertEquals(3L, first.getJSONObject("drops").getJSONObject("malformed").getLong("packets"))
            assertEquals(1L, second.getLong("udpLocalRxPackets"))
            assertEquals(5L, second.getLong("udpFrpcTxPayloadBytes"))
            assertEquals(7L, second.getLong("udpLocalTxBytes"))
        }
    }

    @Test
    fun udpSubmissionWithoutReplyDoesNotInventRemoteDeliveryOrDrops() {
        SocksFixture(dropUdpReplies = true).use { fixture ->
            val events = CopyOnWriteArrayList<String>()
            val port = freeUdpPort()
            val forwarder = Socks5Forwarder(listOf(rule("udp", port, upstream(fixture.port))
                .copy(logContext = context("no-return"))), report = events::add, handshakeTimeoutMs = 3_000)
            try {
                forwarder.start()
                DatagramSocket(0, LOOPBACK).use { client ->
                    val payload = ByteArray(1408) { 17 }
                    client.send(DatagramPacket(payload, payload.size, LOOPBACK, port))
                    client.soTimeout = 350
                    assertThrows(SocketTimeoutException::class.java) { client.receive(DatagramPacket(ByteArray(2048), 2048)) }
                }
            } finally { forwarder.close() }
            assertTrue(waitUntil { finalTraffic(events, port) != null })
            val traffic = finalTraffic(events, port)!!
            assertEquals(1L, traffic.getLong("udpLocalRxPackets"))
            assertEquals(1L, traffic.getLong("udpFrpcTxPackets"))
            assertEquals(1418L, traffic.getLong("udpFrpcTxBytes"))
            assertEquals(1408L, traffic.getLong("udpFrpcTxPayloadBytes"))
            assertEquals(0L, traffic.getLong("udpFrpcRxPackets"))
            assertEquals(0L, traffic.getLong("udpLocalTxPackets"))
            assertEquals(1408, traffic.getInt("udpTxMaxBytes"))
            assertEquals(0L, traffic.getLong("lastRxAtMs"))
            assertEquals(0, traffic.getJSONObject("drops").length())
            assertTrue(traffic.getString("message").contains("not remote delivery confirmation"))
        }
    }

    @Test
    fun udpPendingOverflowOversizeAndShutdownHaveExactDropAccounting() {
        // Hold negotiation until the fixture is closed; VM scheduling must not
        // allow a fixed sleep to expire while these datagrams are queued.
        SocksFixture(authenticationGate = CountDownLatch(1)).use { fixture ->
            val events = CopyOnWriteArrayList<String>()
            val port = freeUdpPort()
            val longestContext = Socks5LogContext("\"".repeat(128), "\\".repeat(160), "i".repeat(128), "n".repeat(160))
            val forwarder = Socks5Forwarder(listOf(rule("udp", port, upstream(fixture.port))
                .copy(logContext = longestContext)), report = events::add, handshakeTimeoutMs = 10_000)
            try {
                forwarder.start()
                DatagramSocket(0, LOOPBACK).use { client ->
                    val payload = ByteArray(64) { 9 }
                    client.send(DatagramPacket(payload, payload.size, LOOPBACK, port))
                    assertTrue(waitUntil { fixture.accepted.get() == 1 })
                    repeat(39) {
                        client.send(DatagramPacket(payload, payload.size, LOOPBACK, port))
                        Thread.sleep(2)
                    }
                    val tooLarge = ByteArray(65_507)
                    client.send(DatagramPacket(tooLarge, tooLarge.size, LOOPBACK, port))
                    Thread.sleep(200)
                }
            } finally { forwarder.close() }
            assertTrue(waitUntil { finalTraffic(events, port) != null })
            val traffic = finalTraffic(events, port)!!
            assertEquals(41L, traffic.getLong("udpLocalRxPackets"))
            assertEquals(0L, traffic.getLong("udpFrpcTxPackets"))
            val drops = traffic.getJSONObject("drops")
            assertEquals(24L, drops.getJSONObject("pendingFull").getLong("packets"))
            assertEquals(24L * 64, drops.getJSONObject("pendingFull").getLong("bytes"))
            assertEquals(1L, drops.getJSONObject("oversize").getLong("packets"))
            assertEquals(16L, drops.getJSONObject("sessionClosed").getLong("packets"))
            assertEquals(16L * 64, drops.getJSONObject("sessionClosed").getLong("bytes"))
            assertTrue(events.all { it.length + "[SOCKS5] ".length < 4096 })
            assertTrue(traffic.getString("message").contains("pendingFull=24"))
        }
    }

    @Test
    fun connectionFailuresAreRateLimitedPerListenerInsteadOfGlobally() {
        SocksFixture(username = "alice", password = "expected-secret").use { fixture ->
            val ports = listOf(freeTcpPort(), freeTcpPort())
            val events = CopyOnWriteArrayList<String>()
            val routes = ports.mapIndexed { index, port -> rule("tcp", port, upstream(fixture.port, "alice", "wrong-secret"))
                .copy(logContext = context("failure-$index")) }
            Socks5Forwarder(routes, report = events::add, handshakeTimeoutMs = 1_000).use { forwarder ->
                forwarder.start()
                for (port in ports + ports.first()) Socket(LOOPBACK, port).use { client ->
                    client.soTimeout = 2_000
                    runCatching { client.getInputStream().read() }
                }
                assertTrue(waitUntil { records(events).count { it.getString("event") == "connect_failed" } == 2 })
                val failures = records(events).filter { it.getString("event") == "connect_failed" }
                assertEquals(ports.toSet(), failures.map { it.getInt("listenPort") }.toSet())
                assertFalse(events.joinToString().contains("wrong-secret"))
                assertFalse(events.joinToString().contains("expected-secret"))
            }
        }
    }

    @Test
    fun highRateUdpUsesPeriodicSummariesAndFlushesFinalCounters() {
        SocksFixture().use { fixture ->
            val events = CopyOnWriteArrayList<String>()
            val port = freeUdpPort()
            val forwarder = Socks5Forwarder(listOf(rule("udp", port, upstream(fixture.port))
                .copy(logContext = context("busy"))), report = events::add, handshakeTimeoutMs = 3_000)
            try {
                forwarder.start()
                DatagramSocket(0, LOOPBACK).use { client ->
                    repeat(1_000) { assertTrue(udpRequest(client, port, "packet-$it").endsWith(":packet-$it")) }
                }
                Thread.sleep(5_200)
                val summaries = records(events).filter { it.getString("event") == "traffic" }
                assertEquals(1, summaries.size) // no unchanged summaries or per-packet log lines
                assertEquals(1_000L, summaries.single().getLong("udpLocalRxPackets"))
                assertEquals(1_000L, summaries.single().getLong("udpLocalTxPackets"))
                assertTrue(events.size < 10)
            } finally { forwarder.close() }
            assertTrue(waitUntil { finalTraffic(events, port) != null })
            assertEquals(1_000L, finalTraffic(events, port)!!.getLong("udpFrpcTxPackets"))
            assertEquals(2, records(events).count { it.getString("event") == "traffic" })
        }
    }

    @Test
    fun defaultModeListensWithoutPreconnecting() {
        SocksFixture().use { fixture ->
            val tcpPort = freeTcpPort()
            val udpPort = freeUdpPort()
            Socks5Forwarder(listOf(rule("tcp", tcpPort, upstream(fixture.port)), rule("udp", udpPort, upstream(fixture.port)))).use { forwarder ->
                forwarder.start()
                // Neither listening TCP nor bound UDP should cause any outbound
                // socket, authentication or ASSOCIATE before application input.
                Thread.sleep(200)
                assertEquals(0, fixture.accepted.get())
                assertEquals(0, fixture.authenticated.get())
                assertTrue(fixture.requests.isEmpty())
                assertEquals("trigger", tcpRequest(tcpPort, "trigger"))
            }
        }
    }

    @Test
    fun immediateTcpAuthenticatesEveryUpstreamWithoutConnectingBusinessTargets() {
        SocksFixture(username = "alice", password = "secret-a", prefix = "one:").use { first ->
            SocksFixture(prefix = "two:").use { second ->
                val port = freeTcpPort()
                val events = CopyOnWriteArrayList<String>()
                val route = rule("tcp", port, upstream(first.port, "alice", "secret-a"), upstream(second.port)).copy(mode = "immediate")
                Socks5Forwarder(listOf(route), report = events::add, handshakeTimeoutMs = 3_000).use { forwarder ->
                    forwarder.start()
                    assertTrue(waitUntil { events.count { it.contains("immediate channel ready") } == 2 })
                    assertEquals(1, first.authenticated.get())
                    assertEquals(1, second.authenticated.get())
                    assertTrue(first.requests.isEmpty())
                    assertTrue(second.requests.isEmpty())
                    assertEquals("one:first", tcpRequest(port, "first"))
                    assertEquals("two:second", tcpRequest(port, "second"))
                    assertEquals(listOf("1/127.0.0.1:32123"), first.requests.toList())
                    assertEquals(listOf("1/127.0.0.1:32123"), second.requests.toList())
                    assertTrue(waitUntil { first.authenticated.get() >= 2 && second.authenticated.get() >= 2 })
                    assertFalse(events.joinToString().contains("secret-a"))
                }
            }
        }
    }

    @Test
    fun immediateUdpAssociatesBeforeTrafficAndKeepsClientSourcesSeparate() {
        SocksFixture(username = "alice", password = "secret-b").use { fixture ->
            val port = freeUdpPort()
            val events = CopyOnWriteArrayList<String>()
            val route = rule("udp", port, upstream(fixture.port, "alice", "secret-b")).copy(mode = "immediate")
            Socks5Forwarder(listOf(route), report = events::add, handshakeTimeoutMs = 3_000).use { forwarder ->
                forwarder.start()
                assertTrue(waitUntil { events.any { it.contains("immediate channel ready") } })
                assertEquals(1, fixture.activeControls.get())
                assertEquals(1, fixture.requests.size)
                assertTrue(fixture.requests.single().startsWith("3/"))
                DatagramSocket(0, LOOPBACK).use { first ->
                    DatagramSocket(0, LOOPBACK).use { second ->
                        val firstReply = udpRequest(first, port, "first")
                        assertTrue(waitUntil { fixture.activeControls.get() >= 2 })
                        val secondReply = udpRequest(second, port, "second")
                        assertNotEquals(firstReply.substringBefore(':'), secondReply.substringBefore(':'))
                        assertEquals(firstReply.substringBefore(':') + ":again", udpRequest(first, port, "again"))
                        assertTrue(waitUntil { fixture.activeControls.get() >= 3 })
                    }
                }
                assertFalse(events.joinToString().contains("secret-b"))
            }
            assertTrue(waitUntil { fixture.activeControls.get() == 0 })
            DatagramSocket(port, LOOPBACK).close()
        }
    }

    @Test
    fun immediateClosedControlIsRebuiltWithoutWaitingForApplicationTraffic() {
        SocksFixture(prefix = "ready:").use { fixture ->
            val port = freeTcpPort()
            val events = CopyOnWriteArrayList<String>()
            Socks5Forwarder(listOf(rule("tcp", port, upstream(fixture.port)).copy(mode = "immediate", logContext = context("retry"))),
                report = events::add, handshakeTimeoutMs = 3_000).use { forwarder ->
                forwarder.start()
                assertTrue(waitUntil { events.any { it.contains("immediate channel ready") } })
                fixture.closeClientControls()
                assertTrue(waitUntil { events.count { it.contains("immediate channel ready") } >= 2 })
                assertTrue(events.any { it.contains("retrying") })
                assertEquals("connection-retry", records(events).first { it.getString("event") == "warm_retry" }.getString("connectionId"))
                assertTrue(fixture.requests.isEmpty())
                assertEquals("ready:reconnected", tcpRequest(port, "reconnected"))
            }
        }
    }

    @Test
    fun immediateChannelsQueueFairlyWithoutReportingBusyWorkersAsNetworkFailures() {
        SocksFixture(authenticationDelayMs = 200).use { fixture ->
            val port = freeTcpPort()
            val events = CopyOnWriteArrayList<String>()
            val upstreams = (1..17).map { upstream(fixture.port).copy(id = "visitor-$it", name = "visitor-$it") }
            val route = rule("tcp", port, *upstreams.toTypedArray()).copy(mode = "immediate")
            Socks5Forwarder(listOf(route), report = events::add, handshakeTimeoutMs = 3_000).use { forwarder ->
                forwarder.start()
                assertTrue(waitUntil { events.count { it.contains("immediate channel ready") } == 17 })
                assertEquals(17, fixture.authenticated.get())
                assertTrue(fixture.requests.isEmpty())
                assertFalse(events.any { it.contains("unavailable") || it.contains("retrying") })
            }
        }
    }

    @Test
    fun immediatePendingHandshakesDoNotStarveRequestsAndStopClosesEveryWarmSocket() {
        ServerSocket(0, 16, LOOPBACK).use { silent ->
            val accepted = CountDownLatch(8)
            val remoteClosed = CountDownLatch(8)
            val sockets = ConcurrentHashMap<Socket, Boolean>()
            val acceptThread = Thread {
                repeat(8) {
                    val socket = silent.accept()
                    sockets[socket] = true
                    accepted.countDown()
                    Thread {
                        try { while (socket.getInputStream().read() >= 0) { } }
                        finally { socket.close(); sockets.remove(socket); remoteClosed.countDown() }
                    }.apply { isDaemon = true; start() }
                }
            }.apply { isDaemon = true; start() }
            SocksFixture(prefix = "business:").use { fixture ->
                val reservations = List(8) { ServerSocket(0, 1, LOOPBACK) }
                val warmPorts = reservations.map { it.localPort }
                reservations.forEach { it.close() }
                val businessPort = freeTcpPort()
                val routes = warmPorts.map { rule("tcp", it, upstream(silent.localPort)).copy(mode = "immediate") } +
                    rule("tcp", businessPort, upstream(fixture.port))
                val events = CopyOnWriteArrayList<String>()
                val forwarder = Socks5Forwarder(routes, report = events::add)
                try {
                    forwarder.start()
                    assertTrue(accepted.await(3, TimeUnit.SECONDS))
                    assertEquals("business:available", tcpRequest(businessPort, "available"))
                    forwarder.close()
                    assertTrue(remoteClosed.await(2, TimeUnit.SECONDS))
                    assertFalse(events.any { it.contains("unavailable") || it.contains("retrying") })
                    ServerSocket(warmPorts.first(), 1, LOOPBACK).close()
                } finally {
                    forwarder.close()
                    sockets.keys.forEach { runCatching { it.close() } }
                    silent.close()
                    acceptThread.join(1_000)
                }
            }
        }
    }

    @Test
    fun tcpForwardsTargetAndPreservesHalfClose() {
        SocksFixture(prefix = "half:").use { fixture ->
            val port = freeTcpPort()
            Socks5Forwarder(listOf(rule("tcp", port, upstream(fixture.port))), handshakeTimeoutMs = 3_000).use { forwarder ->
                forwarder.start()
                assertEquals("half:hello", tcpRequest(port, "hello"))
                assertEquals(listOf("1/127.0.0.1:32123"), fixture.requests.toList())
            }
            ServerSocket(port, 1, LOOPBACK).close()
        }
    }

    @Test
    fun persistentTcpConnectionCompletesTwoRoundTripsWithoutHalfClose() {
        SocksFixture(streamingTcp = true).use { fixture ->
            val port = freeTcpPort()
            Socks5Forwarder(listOf(rule("tcp", port, upstream(fixture.port))), handshakeTimeoutMs = 3_000).use { forwarder ->
                forwarder.start()
                Socket(LOOPBACK, port).use { socket ->
                    socket.soTimeout = 1_500
                    val started = System.nanoTime()
                    for (message in listOf("first persistent request", "second persistent request")) {
                        val payload = message.toByteArray(Charsets.UTF_8)
                        socket.getOutputStream().write(payload)
                        assertArrayEquals(payload, read(socket.getInputStream(), payload.size))
                        assertFalse(socket.isOutputShutdown)
                    }
                    val elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
                    assertTrue("Two persistent TCP round trips took ${elapsed}ms", elapsed < 2_000)
                    assertEquals(1, fixture.authenticated.get())
                    assertEquals(1, fixture.requests.size)
                }
            }
        }
    }

    @Test
    fun tcpAuthenticatesAndUsesEveryConfiguredVisitorWithoutMixingStreams() {
        SocksFixture(username = "alice", password = "password-one", prefix = "one:").use { first ->
            SocksFixture(username = "bob", password = "", prefix = "two:").use { second ->
                val port = freeTcpPort()
                val route = rule("tcp", port, upstream(first.port, "alice", "password-one"), upstream(second.port, "bob", ""))
                Socks5Forwarder(listOf(route), handshakeTimeoutMs = 3_000).use { forwarder ->
                    forwarder.start()
                    assertEquals("one:first", tcpRequest(port, "first"))
                    assertEquals("two:second", tcpRequest(port, "second"))
                    assertEquals("one:third", tcpRequest(port, "third"))
                    assertEquals(2, first.authenticated.get())
                    assertEquals(1, second.authenticated.get())
                }
            }
        }
    }

    @Test
    fun failedVisitorTriesOtherConfiguredVisitorAndWrongCredentialsFailClosed() {
        SocksFixture(username = "alice", password = "correct", prefix = "ok:").use { fixture ->
            val port = freeTcpPort()
            val route = rule("tcp", port, upstream(freeTcpPort()), upstream(fixture.port, "alice", "correct"))
            Socks5Forwarder(listOf(route), handshakeTimeoutMs = 3_000).use { forwarder ->
                forwarder.start()
                assertEquals("ok:fallback", tcpRequest(port, "fallback"))
            }
            val warnings = Collections.synchronizedList(mutableListOf<String>())
            Socks5Forwarder(listOf(rule("tcp", port, upstream(fixture.port, "alice", "incorrect-secret"))),
                report = warnings::add, handshakeTimeoutMs = 3_000).use { forwarder ->
                forwarder.start()
                Socket(LOOPBACK, port).use { socket ->
                    socket.soTimeout = 4_000
                    assertEquals(-1, socket.getInputStream().read())
                }
                assertTrue(warnings.isNotEmpty())
                assertFalse(warnings.joinToString().contains("incorrect-secret"))
                assertEquals(1, fixture.requests.size)
            }
        }
    }

    @Test
    fun udpAssociationsAuthenticateIsolateClientsRejectFragmentsAndReleaseControls() {
        SocksFixture(username = "alice", password = "", fragmentedReplyFirst = true).use { fixture ->
            val port = freeUdpPort()
            val route = rule("udp", port, upstream(fixture.port, "alice", ""))
            Socks5Forwarder(listOf(route), handshakeTimeoutMs = 3_000).use { forwarder ->
                forwarder.start()
                DatagramSocket(0, LOOPBACK).use { first ->
                    DatagramSocket(0, LOOPBACK).use { second ->
                        val firstReply = udpRequest(first, port, "first")
                        val secondReply = udpRequest(second, port, "second")
                        assertTrue(firstReply.endsWith(":first"))
                        assertTrue(secondReply.endsWith(":second"))
                        assertNotEquals(firstReply.substringBefore(':'), secondReply.substringBefore(':'))
                        assertEquals(firstReply.substringBefore(':') + ":again", udpRequest(first, port, "again"))
                        assertEquals(2, fixture.authenticated.get())
                        assertEquals(2, fixture.activeControls.get())
                    }
                }
            }
            assertTrue(waitUntil { fixture.activeControls.get() == 0 })
            DatagramSocket(port, LOOPBACK).close()
        }
    }

    @Test
    fun idleUdpSessionsCloseTheirControlConnections() {
        SocksFixture().use { fixture ->
            val port = freeUdpPort()
            Socks5Forwarder(listOf(rule("udp", port, upstream(fixture.port))),
                handshakeTimeoutMs = 3_000, udpIdleTimeoutMs = 150).use { forwarder ->
                forwarder.start()
                DatagramSocket(0, LOOPBACK).use { client ->
                    assertTrue(udpRequest(client, port, "idle").endsWith(":idle"))
                    assertTrue(waitUntil { fixture.activeControls.get() == 0 })
                    assertTrue(udpRequest(client, port, "new-session").endsWith(":new-session"))
                    assertEquals(2, fixture.authenticated.get())
                }
            }
        }
    }

    @Test
    fun bindFailureRollsBackPreviouslyBoundListeners() {
        ServerSocket(0, 1, LOOPBACK).use { occupied ->
            val availablePort = freeTcpPort()
            val events = CopyOnWriteArrayList<String>()
            val routes = listOf(rule("tcp", availablePort, upstream(1080)).copy(logContext = context("available")),
                rule("tcp", occupied.localPort, upstream(1080)).copy(logContext = context("occupied")))
            Socks5Forwarder(routes, report = events::add).use { forwarder ->
                assertThrows(Exception::class.java) { forwarder.start() }
                ServerSocket(availablePort, 1, LOOPBACK).close()
                val failure = records(events).single { it.getString("event") == "listen_failed" }
                assertEquals(occupied.localPort, failure.getInt("listenPort"))
                assertEquals("connection-occupied", failure.getString("connectionId"))
            }
        }
    }

    @Test
    fun shutdownCancelsPendingAuthenticationAndReleasesListener() {
        ServerSocket(0, 1, LOOPBACK).use { silent ->
            val accepted = CountDownLatch(1)
            val remoteClosed = CountDownLatch(1)
            val worker = Thread {
                silent.accept().use { socket ->
                    socket.soTimeout = 4_000
                    accepted.countDown()
                    try { while (socket.getInputStream().read() >= 0) { } } finally { remoteClosed.countDown() }
                }
            }.apply { isDaemon = true; start() }
            val port = freeTcpPort()
            val forwarder = Socks5Forwarder(listOf(rule("tcp", port, upstream(silent.localPort))))
            try {
                forwarder.start()
                Socket(LOOPBACK, port).use { client ->
                    client.soTimeout = 4_000
                    assertTrue(accepted.await(3, TimeUnit.SECONDS))
                    forwarder.close()
                    assertEquals(-1, client.getInputStream().read())
                    assertTrue(remoteClosed.await(2, TimeUnit.SECONDS))
                }
                ServerSocket(port, 1, LOOPBACK).close()
            } finally { forwarder.close(); worker.join(3_000) }
        }
    }

    private fun rule(protocol: String, port: Int, vararg upstreams: Socks5Upstream) =
        Socks5ForwardRule(protocol, "127.0.0.1", port, "127.0.0.1", 32123, upstreams.toList())

    private fun context(id: String) = Socks5LogContext("config-$id", "Configuration $id", "connection-$id", "Ports $id")

    private fun records(events: List<String>): List<JSONObject> = events.map { JSONObject(it) }

    private fun finalTraffic(events: List<String>, port: Int): JSONObject? = records(events).lastOrNull {
        it.getString("event") == "traffic" && it.optBoolean("final") && it.getInt("listenPort") == port
    }

    private fun upstream(port: Int, username: String = "", password: String = "") =
        Socks5Upstream("visitor-$port", "visitor-$port", "127.0.0.1", port, username, password)

    private fun tcpRequest(port: Int, text: String): String = Socket(LOOPBACK, port).use { socket ->
        socket.soTimeout = 4_000
        socket.getOutputStream().write(text.toByteArray())
        socket.shutdownOutput()
        socket.getInputStream().readBytes().toString(Charsets.UTF_8)
    }

    private fun udpRequest(socket: DatagramSocket, port: Int, text: String): String {
        socket.soTimeout = 4_000
        val body = text.toByteArray()
        socket.send(DatagramPacket(body, body.size, LOOPBACK, port))
        val reply = DatagramPacket(ByteArray(1024), 1024)
        socket.receive(reply)
        assertEquals(port, reply.port)
        return reply.data.copyOf(reply.length).toString(Charsets.UTF_8)
    }

    private fun freeTcpPort(): Int = ServerSocket(0, 1, LOOPBACK).use { it.localPort }
    private fun freeUdpPort(): Int = DatagramSocket(0, LOOPBACK).use { it.localPort }

    private fun waitUntil(condition: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(4)
        while (System.nanoTime() < deadline) {
            if (condition()) return true
            Thread.sleep(25)
        }
        return condition()
    }

    private class SocksFixture(
        private val username: String = "",
        private val password: String = "",
        private val prefix: String = "",
        private val fragmentedReplyFirst: Boolean = false,
        private val malformedReplyFirst: Boolean = false,
        private val dropUdpReplies: Boolean = false,
        private val streamingTcp: Boolean = false,
        private val authenticationDelayMs: Long = 0,
        private val authenticationGate: CountDownLatch? = null,
    ) : Closeable {
        private val server = ServerSocket(0, 8, LOOPBACK)
        private val sockets = ConcurrentHashMap<Closeable, Boolean>()
        private val closed = AtomicBoolean(false)
        private val sequence = AtomicInteger()
        val accepted = AtomicInteger()
        val authenticated = AtomicInteger()
        val activeControls = AtomicInteger()
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val port: Int get() = server.localPort

        init {
            Thread {
                while (!closed.get()) {
                    val socket = try { server.accept() } catch (_: Exception) { break }
                    sockets[socket] = true
                    accepted.incrementAndGet()
                    Thread { try { handle(socket) } catch (_: Exception) { } finally {
                        socket.close(); sockets.remove(socket)
                    } }.apply { isDaemon = true; start() }
                }
            }.apply { isDaemon = true; start() }
        }

        private fun handle(socket: Socket) {
            socket.soTimeout = 4_000
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            val hello = read(input, 2)
            assertEquals(5, hello[0].toInt())
            val methods = read(input, hello[1].toInt() and 255)
            val method = if (username.isEmpty() && password.isEmpty()) 0 else 2
            if (method.toByte() !in methods) { output.write(byteArrayOf(5, -1)); return }
            if (authenticationDelayMs > 0) Thread.sleep(authenticationDelayMs)
            authenticationGate?.await()
            if (closed.get() || socket.isClosed) return
            output.write(byteArrayOf(5, method.toByte()))
            if (method == 2) {
                val auth = read(input, 2)
                val actualUser = read(input, auth[1].toInt() and 255).toString(Charsets.UTF_8)
                val actualPassword = read(input, input.read()).toString(Charsets.UTF_8)
                val ok = actualUser == username && actualPassword == password
                output.write(byteArrayOf(1, if (ok) 0 else 1))
                if (!ok) return
            }
            authenticated.incrementAndGet()
            val request = read(input, 3)
            val type = input.read()
            val host = InetAddress.getByAddress(read(input, if (type == 1) 4 else 16)).hostAddress
            val portBytes = read(input, 2)
            val port = ((portBytes[0].toInt() and 255) shl 8) or (portBytes[1].toInt() and 255)
            requests.add("${request[1]}/$host:$port")
            if (request[1].toInt() == 1) {
                output.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 1))
                if (streamingTcp) {
                    val buffer = ByteArray(4096)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count > 0) output.write(buffer, 0, count)
                    }
                } else {
                    val data = input.readBytes()
                    output.write(prefix.toByteArray() + data)
                }
                socket.shutdownOutput()
            } else {
                val associationId = sequence.incrementAndGet()
                val udp = DatagramSocket(0, LOOPBACK)
                udp.soTimeout = 1_000
                sockets[udp] = true
                activeControls.incrementAndGet()
                try {
                    output.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1,
                        (udp.localPort shr 8).toByte(), udp.localPort.toByte()))
                    Thread {
                        while (!closed.get() && !udp.isClosed) {
                            val packet = DatagramPacket(ByteArray(2048), 2048)
                            try { udp.receive(packet) } catch (_: SocketTimeoutException) { continue } catch (_: Exception) { break }
                            if (dropUdpReplies) continue
                            val data = packet.data.copyOf(packet.length)
                            val addressSize = if (data[3].toInt() == 1) 4 else 16
                            val headerSize = 4 + addressSize + 2
                            val reply = data.copyOf(headerSize) + "$associationId:".toByteArray() + data.copyOfRange(headerSize, data.size)
                            if (malformedReplyFirst) {
                                val malformed = byteArrayOf(0, 0, 0, 0)
                                udp.send(DatagramPacket(malformed, malformed.size, packet.socketAddress))
                            }
                            if (fragmentedReplyFirst) {
                                val fragment = reply.copyOf().also { it[2] = 1 }
                                udp.send(DatagramPacket(fragment, fragment.size, packet.socketAddress))
                            }
                            udp.send(DatagramPacket(reply, reply.size, packet.socketAddress))
                        }
                    }.apply { isDaemon = true; start() }
                    socket.soTimeout = 0
                    while (input.read() >= 0) { }
                } finally { udp.close(); sockets.remove(udp); activeControls.decrementAndGet() }
            }
        }

        fun closeClientControls() {
            sockets.keys.filterIsInstance<Socket>().forEach { runCatching { it.close() } }
        }

        override fun close() {
            closed.set(true)
            authenticationGate?.countDown()
            server.close()
            sockets.keys.forEach { runCatching { it.close() } }
            sockets.clear()
        }
    }

    companion object {
        private val LOOPBACK = InetAddress.getByName("127.0.0.1")
        private fun read(input: InputStream, count: Int): ByteArray {
            require(count >= 0)
            val bytes = ByteArray(count)
            var position = 0
            while (position < count) {
                val size = input.read(bytes, position, count - position)
                check(size >= 0)
                position += size
            }
            return bytes
        }
    }
}
