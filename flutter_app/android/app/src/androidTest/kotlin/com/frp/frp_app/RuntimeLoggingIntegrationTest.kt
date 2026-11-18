package com.frp.frp_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RuntimeLoggingIntegrationTest {
    private class HoldingChannel : MethodChannel(object : BinaryMessenger {
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {}
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {}
    }, "test/release-log-batches") {
        val batches = mutableListOf<Pair<Long, MethodChannel.Result>>()
        override fun invokeMethod(method: String, arguments: Any?, callback: MethodChannel.Result?) {
            if (method == "onLogBatch") {
                batches += (arguments as Map<*, *>)["firstId"] as Long to checkNotNull(callback)
            }
        }
    }

    @Test
    fun logBatchesWaitForTheirReaderAndIgnoreStaleAcknowledgements() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val old = HoldingChannel()
        val current = HoldingChannel()
        val previous = FrpcService.channel
        fun step(action: () -> Unit) {
            instrumentation.runOnMainSync(action)
            instrumentation.waitForIdleSync()
        }
        fun startReader(channel: HoldingChannel) {
            FrpcService.channel = channel
            FrpcService.setLogSubscription(channel, true)
            repeat(130) { FrpcService.recordLog("reader test row $it") }
            FrpcService.setLogUiStarted(channel, true)
        }
        try {
            step { startReader(old) }
            val (start, ack) = old.batches.single()
            step {
                FrpcService.setLogUiStarted(old, false)
                ack.success(null)
            }
            assertEquals(1, old.batches.size)
            step { FrpcService.setLogUiStarted(old, true) }
            assertEquals(start + 64, old.batches.last().first)
            step { startReader(current) }
            val (newStart, newAck) = current.batches.single()
            step { old.batches.last().second.success(null) }
            assertEquals(1, current.batches.size)
            step { newAck.error("fixture", "decode failed", null) }
            assertEquals(1, current.batches.size)
            step { FrpcService.setLogUiStarted(current, true) }
            assertEquals(newStart, current.batches.last().first)
            step { current.batches.last().second.success(null) }
            assertEquals(newStart + 64, current.batches.last().first)
            step {
                FrpcService.setLogSubscription(current, false)
                current.batches.last().second.success(null)
            }
            assertEquals(3, current.batches.size)
        } finally {
            step { FrpcService.channel = previous }
        }
    }

    @Test
    fun subscribedReaderCatchesUpInBoundedOrderedBatchesAfterRingOverflow() {
        val history = FrpcService.readLogSnapshot()
        val startId = (history["firstId"] as Long) + (history["lines"] as List<*>).size
        val marker = UUID.randomUUID().toString()
        for (i in 0..2010) FrpcService.recordLog("$marker/$i")
        val (first, firstBatch) = FrpcService.readLogBatch(startId)
        assertEquals(startId + 11, first)
        assertEquals((11 until 75).map { "$marker/$it" }, firstBatch)
        val (second, nextBatch) = FrpcService.readLogBatch(first + firstBatch.size)
        assertEquals(startId + 75, second)
        assertEquals((75 until 139).map { "$marker/$it" }, nextBatch)
        val (tail, lastBatch) = FrpcService.readLogBatch(startId + 2008)
        assertEquals(startId + 2008, tail)
        assertEquals((2008..2010).map { "$marker/$it" }, lastBatch)
        assertTrue(FrpcService.readLogBatch(tail + lastBatch.size).second.isEmpty())
    }

    @Test
    fun preServiceDiagnosticsAreBoundedAndRedactedInTheSharedHistory() {
        val marker = UUID.randomUUID().toString()
        // No service start or recovery-preference mutation is needed to retain
        // startup STUN output and SOCKS diagnostics in the same history.
        val before = FrpcService.readLogSnapshot()
        val expectedFirstId = before["firstId"] as Long + (before["lines"] as List<*>).size + 2
        for (index in 0..2000) FrpcService.recordLog("[STUN] $marker/$index")
        FrpcService.recordLog("[SOCKS5] $marker password=fixture-secret")
        val lines = FrpcService.readRecentLogs().lines()
        val snapshot = FrpcService.readLogSnapshot()
        assertEquals(expectedFirstId, snapshot["firstId"])
        assertEquals(lines, snapshot["lines"])
        assertEquals(2000, lines.size)
        assertEquals("[STUN] $marker/2", lines.first())
        assertTrue(lines.last().contains("password=***"))
        assertFalse(lines.any { it.contains("fixture-secret") })
    }
}
