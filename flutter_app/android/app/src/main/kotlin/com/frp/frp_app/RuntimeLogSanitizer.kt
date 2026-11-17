package com.frp.frp_app

import org.json.JSONArray
import org.json.JSONObject

/** Bounded credential redaction which preserves structured SOCKS ownership. */
internal object RuntimeLogSanitizer {
    const val MAX_LOG_LINE_CHARS = 4096
    const val TRUNCATED_LOG_SUFFIX = " … [truncated]"
    private const val SECRET_KEYS = """authorization|token|secret(?:[\s_-]*key)?|client[\s_-]*secret|password|passwd|credential|api[\s_-]*key|private[\s_-]*key|access[\s_-]*key|cookie|sk"""
    private val secretKey = Regex("^(?:$SECRET_KEYS)$", RegexOption.IGNORE_CASE)
    private val ansiEscape = Regex("\u001B\\[[;\\d]*m")

    private val field = Regex(
        """(?i)(?<![\w-])(?:(['\"]?)($SECRET_KEYS)\1)(?![\w-])\s*([=:])\s*(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|(?:bearer\s+)?[^\r\n,;}\]]+?(?=\s+(?:['\"]?(?:$SECRET_KEYS)['\"]?)(?![\w-])\s*[=:]|[,;}\]]|$))""",
    )

    fun redact(line: String): String {
        return line.replace(field) { match ->
            val quote = match.groupValues[1]
            val name = match.groupValues[2]
            val separator = match.groupValues[3]
            if (quote.isNotEmpty()) {
                "$quote$name$quote$separator$quote***$quote"
            } else {
                "$name=***"
            }
        }
    }

    fun sanitize(raw: String): String {
        val bounded = bound(raw)
        val clean = bounded.replace(ansiEscape, "")
        if (raw.length <= MAX_LOG_LINE_CHARS && clean.startsWith("[SOCKS5]")) {
            val structured = runCatching {
                val value = JSONObject(clean.removePrefix("[SOCKS5]").trimStart())
                require(value.optInt("v") == 1)
                sanitizeValue(value, 0)
                "[SOCKS5] $value"
            }.getOrNull()
            if (structured != null && structured.length <= MAX_LOG_LINE_CHARS) return structured
        }
        // Replacing an empty credential with *** can grow the bounded input.
        return bound(redact(clean))
    }

    private fun bound(value: String): String = if (value.length <= MAX_LOG_LINE_CHARS) value
        else value.take(MAX_LOG_LINE_CHARS - TRUNCATED_LOG_SUFFIX.length) + TRUNCATED_LOG_SUFFIX

    private fun sanitizeValue(value: Any?, depth: Int): Any? {
        if (value is String) return redact(value)
        if (depth >= 16) return "[nested value omitted]"
        when (value) {
            is JSONObject -> {
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    value.put(key, if (secretKey.matches(key)) "***"
                        else sanitizeValue(value.get(key), depth + 1))
                }
            }
            is JSONArray -> for (index in 0 until value.length()) {
                value.put(index, sanitizeValue(value.get(index), depth + 1))
            }
        }
        return value
    }
}
