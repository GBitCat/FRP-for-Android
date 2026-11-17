package com.frp.frp_app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeLogSanitizerTest {
    @Test
    fun structuredNamesRemainParseableAndOwnershipSurvivesRedaction() {
        val event = JSONObject().put("v", 1).put("configKey", "SERVER01/group/7")
            .put("connectionId", "ports-01").put("configName", "Group [A] \"quoted\" password=private-one")
            .put("connectionName", "Ports \"B\" token=private-two")
            .put("protocol", "udp").put("listenPort", 5513).put("event", "traffic")
            .put("message", "Submitted to local frpc; password=private-three")
            .put("udpFrpcTxPayloadBytes", 14080)
        val line = RuntimeLogSanitizer.sanitize("[SOCKS5] $event")
        val decoded = JSONObject(line.removePrefix("[SOCKS5] "))
        assertEquals("SERVER01/group/7", decoded.getString("configKey"))
        assertEquals("ports-01", decoded.getString("connectionId"))
        assertEquals(14080, decoded.getInt("udpFrpcTxPayloadBytes"))
        assertTrue(decoded.getString("configName").contains("\"quoted\""))
        assertTrue(decoded.getString("message").contains("password=***"))
        for (secret in listOf("private-one", "private-two", "private-three")) assertFalse(line.contains(secret))
    }

    @Test
    fun structuredCredentialFieldsAreRedactedAtEveryLevel() {
        val event = JSONObject().put("v", 1).put("password", "private-one")
            .put("extra", JSONObject().put("secretKey", "private-two").put("count", 3))
            .put("items", JSONArray().put(JSONObject().put("Authorization", "Bearer private-three")))
        val line = RuntimeLogSanitizer.sanitize("[SOCKS5] $event")
        val decoded = JSONObject(line.removePrefix("[SOCKS5] "))
        assertEquals("***", decoded.getString("password"))
        assertEquals("***", decoded.getJSONObject("extra").getString("secretKey"))
        assertEquals(3, decoded.getJSONObject("extra").getInt("count"))
        assertEquals("***", decoded.getJSONArray("items").getJSONObject(0).getString("Authorization"))
        assertFalse(line.contains("private-"))
    }

    @Test
    fun legacyLogsRetainCredentialMaskingAnsiRemovalAndLengthBounds() {
        val line = RuntimeLogSanitizer.sanitize("\u001B[31m[W] password=private-one, token=private-two\u001B[0m")
        assertFalse(line.contains("private-"))
        assertFalse(line.contains('\u001B'))
        assertTrue(line.contains("password=***"))
        val oversized = RuntimeLogSanitizer.sanitize("x".repeat(8192))
        assertEquals(RuntimeLogSanitizer.MAX_LOG_LINE_CHARS, oversized.length)
        assertTrue(oversized.endsWith(RuntimeLogSanitizer.TRUNCATED_LOG_SUFFIX))
        val malformed = RuntimeLogSanitizer.sanitize("[SOCKS5] {not-json, password=private-one}")
        assertFalse(malformed.contains("private-one"))
        val emptySecrets = "password=\"\", ".repeat(310)
        assertTrue(emptySecrets.length <= RuntimeLogSanitizer.MAX_LOG_LINE_CHARS)
        val expanded = RuntimeLogSanitizer.sanitize(emptySecrets)
        assertEquals(RuntimeLogSanitizer.MAX_LOG_LINE_CHARS, expanded.length)
        assertTrue(expanded.endsWith(RuntimeLogSanitizer.TRUNCATED_LOG_SUFFIX))
    }
}
