package com.frp.frp_app

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RuntimeLoggingIntegrationTest {
    @Test
    fun preServiceDiagnosticsAreBoundedAndRedactedInTheSharedHistory() {
        val marker = UUID.randomUUID().toString()
        // No service start or recovery-preference mutation is needed to retain
        // startup STUN output and SOCKS diagnostics in the same history.
        for (index in 0..2000) FrpcService.recordLog("[STUN] $marker/$index")
        FrpcService.recordLog("[SOCKS5] $marker password=fixture-secret")
        val lines = FrpcService.readRecentLogs().lines()
        assertEquals(2000, lines.size)
        assertEquals("[STUN] $marker/2", lines.first())
        assertTrue(lines.last().contains("password=***"))
        assertFalse(lines.any { it.contains("fixture-secret") })
    }
}
