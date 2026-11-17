package com.frp.frp_app

import org.json.JSONObject

/** Display/filter identity only. Credentials and destinations never belong here. */
internal data class Socks5LogContext(
    val configKey: String,
    val configName: String,
    val connectionId: String,
    val connectionName: String,
) {
    init {
        validate(configKey, 128, true, false)
        validate(configName, 160, false, true)
        validate(connectionId, 128, true, false)
        validate(connectionName, 160, false, true)
    }

    fun toJson(): JSONObject = JSONObject().put("configKey", configKey).put("configName", configName)
        .put("connectionId", connectionId).put("connectionName", connectionName)

    companion object {
        private val fields = setOf("configKey", "configName", "connectionId", "connectionName")

        fun fromJson(value: Any): Socks5LogContext {
            require(value is JSONObject && value.keys().asSequence().toSet() == fields) { "Invalid SOCKS5 log context" }
            fun field(key: String): String {
                val text = value.get(key)
                require(text is String) { "Invalid SOCKS5 log context field" }
                return text
            }
            return Socks5LogContext(field("configKey"), field("configName"), field("connectionId"), field("connectionName"))
        }

        private fun validate(value: String, maximum: Int, nonempty: Boolean, displayName: Boolean) {
            require(value.length <= maximum && (!nonempty || value.isNotEmpty()) &&
                value.none { it.code < 32 || it.code == 127 || (displayName && it.code in 128..159) }) {
                "Invalid SOCKS5 log context field"
            }
        }
    }
}

/** Bound a complete JSON object before FrpcService's line cap can truncate it.
 * Filter identities and numerical observations remain intact; unusually large
 * display labels/descriptions can be shortened without changing their identity.
 */
internal object Socks5LogFormatter {
    private const val MAX_CHARS = 3900 // headroom for [SOCKS5] and service timestamps

    fun line(rule: Socks5ForwardRule, event: String, message: String, extra: JSONObject? = null): String {
        val context = rule.logContext ?: return "${rule.protocol.uppercase()} ${rule.listenPort}: $message"
        val result = context.toJson().put("v", 1).put("protocol", rule.protocol).put("listenPort", rule.listenPort)
            .put("event", event).put("message", message).put("timestampMs", System.currentTimeMillis())
        extra?.let { values -> values.keys().forEach { key -> result.put(key, values.get(key)) } }
        fun encoded() = result.toString()
        fun shortenNames(maximum: Int) {
            for (key in arrayOf("configName", "connectionName")) {
                val value = result.getString(key)
                if (value.length > maximum) result.put(key, value.take(maximum) + "…")
            }
        }
        var text = encoded()
        if (text.length <= MAX_CHARS) return text
        shortenNames(48)
        text = encoded()
        if (text.length <= MAX_CHARS) return text
        if (message.length > 160) result.put("message", message.take(160) + "…")
        // The scope is implied by the reason (malformed/fragmented are frames,
        // other reasons are payload); redundant labels can be removed first.
        result.optJSONObject("drops")?.let { drops ->
            drops.keys().forEach { key -> drops.optJSONObject(key)?.remove("byteScope") }
        }
        text = encoded()
        if (text.length <= MAX_CHARS) return text
        shortenNames(16)
        text = encoded()
        if (text.length <= MAX_CHARS) return text
        // Defensive future-schema fallback: never let logging stop forwarding
        // or emit truncated JSON that cannot be filtered. Current fields and
        // their admitted bounds fit without this fallback (covered by tests).
        val minimal = context.toJson().put("v", 1).put("protocol", rule.protocol).put("listenPort", rule.listenPort)
            .put("event", event).put("message", "SOCKS5 event exceeded the log size limit")
            .put("timestampMs", System.currentTimeMillis())
            .put("configName", context.configName.take(16)).put("connectionName", context.connectionName.take(16))
        return minimal.toString()
    }
}

internal enum class Socks5Drop(val field: String) {
    PENDING_FULL("pendingFull"), OVERSIZE("oversize"), MALFORMED("malformed"),
    FRAGMENTED("fragmented"), WRITE_ZERO("writeZero"), WRITE_PARTIAL("writePartial"),
    WRITE_ERROR("writeError"), SESSION_CLOSED("sessionClosed"), SESSION_LIMIT("sessionLimit"),
    WORKER_REJECTED("workerRejected"),
}

/** One small monitor per listener, never held around I/O, logging or formatting.
 * Counters are cumulative; a coherent snapshot prevents packet/byte mismatches.
 * FRPC UDP byte counters include the SOCKS header; payload counters do not.
 */
internal class Socks5TrafficStats {
    private var revision = 0L
    private val packets = LongArray(4)
    private val bytes = LongArray(4)
    private var frpcTxPayloadBytes = 0L
    private var frpcRxPayloadBytes = 0L
    private var tcpFrpcTxBytes = 0L
    private var tcpLocalTxBytes = 0L
    private var txMin = Int.MAX_VALUE
    private var txMax = 0
    private var rxMin = Int.MAX_VALUE
    private var rxMax = 0
    private var lastTxAtMs = 0L
    private var lastRxAtMs = 0L
    private val dropPackets = LongArray(Socks5Drop.entries.size)
    private val dropBytes = LongArray(Socks5Drop.entries.size)

    @Synchronized fun udpLocalReceived(size: Int) {
        packets[0]++; bytes[0] += size
        txMin = minOf(txMin, size); txMax = maxOf(txMax, size)
        lastTxAtMs = System.currentTimeMillis(); revision++
    }

    @Synchronized fun udpFrpcSubmitted(frameBytes: Int, payloadBytes: Int) {
        packets[1]++; bytes[1] += frameBytes; frpcTxPayloadBytes += payloadBytes; revision++
    }

    @Synchronized fun udpFrpcReceived(frameBytes: Int) {
        packets[2]++; bytes[2] += frameBytes; revision++
    }

    @Synchronized fun udpFrpcPayload(size: Int) {
        frpcRxPayloadBytes += size
        rxMin = minOf(rxMin, size); rxMax = maxOf(rxMax, size); revision++
    }

    @Synchronized fun udpLocalSubmitted(size: Int) {
        packets[3]++; bytes[3] += size
        lastRxAtMs = System.currentTimeMillis(); revision++
    }

    @Synchronized fun tcpSubmitted(toFrpc: Boolean, size: Int) {
        if (size <= 0) return
        if (toFrpc) { tcpFrpcTxBytes += size; lastTxAtMs = System.currentTimeMillis() }
        else { tcpLocalTxBytes += size; lastRxAtMs = System.currentTimeMillis() }
        revision++
    }

    @Synchronized fun drop(reason: Socks5Drop, size: Int, count: Int = 1) {
        if (count <= 0) return
        dropPackets[reason.ordinal] += count; dropBytes[reason.ordinal] += size; revision++
    }

    @Synchronized fun snapshot(afterRevision: Long): Snapshot? {
        if (revision == 0L || revision == afterRevision) return null
        return Snapshot(revision, packets.copyOf(), bytes.copyOf(), frpcTxPayloadBytes, frpcRxPayloadBytes,
            tcpFrpcTxBytes, tcpLocalTxBytes, if (txMin == Int.MAX_VALUE) 0 else txMin, txMax,
            if (rxMin == Int.MAX_VALUE) 0 else rxMin, rxMax, lastTxAtMs, lastRxAtMs,
            dropPackets.copyOf(), dropBytes.copyOf())
    }

    internal data class Snapshot(
        val revision: Long, val packets: LongArray, val bytes: LongArray,
        val frpcTxPayloadBytes: Long, val frpcRxPayloadBytes: Long,
        val tcpFrpcTxBytes: Long, val tcpLocalTxBytes: Long,
        val txMin: Int, val txMax: Int, val rxMin: Int, val rxMax: Int,
        val lastTxAtMs: Long, val lastRxAtMs: Long,
        val dropPackets: LongArray, val dropBytes: LongArray,
    ) {
        fun json(protocol: String): JSONObject {
            val result = JSONObject().put("cumulative", true)
                .put("lastTxAtMs", lastTxAtMs).put("lastRxAtMs", lastRxAtMs)
            if (protocol == "udp") {
                val names = arrayOf("udpLocalRx", "udpFrpcTx", "udpFrpcRx", "udpLocalTx")
                for (i in names.indices) result.put(names[i] + "Packets", packets[i]).put(names[i] + "Bytes", bytes[i])
                result.put("udpFrpcTxPayloadBytes", frpcTxPayloadBytes).put("udpFrpcRxPayloadBytes", frpcRxPayloadBytes)
                    .put("udpTxMinBytes", txMin).put("udpTxMaxBytes", txMax)
                    .put("udpRxMinBytes", rxMin).put("udpRxMaxBytes", rxMax)
            } else result.put("tcpFrpcTxBytes", tcpFrpcTxBytes).put("tcpLocalTxBytes", tcpLocalTxBytes)
            val drops = JSONObject()
            for (reason in Socks5Drop.entries) if (dropPackets[reason.ordinal] != 0L) {
                drops.put(reason.field, JSONObject().put("packets", dropPackets[reason.ordinal]).put("bytes", dropBytes[reason.ordinal])
                    .put("byteScope", if (reason == Socks5Drop.MALFORMED || reason == Socks5Drop.FRAGMENTED) "socksFrame" else "payload"))
            }
            result.put("drops", drops)
            return result
        }

        fun message(protocol: String): String {
            val loss = dropPackets.sum()
            val reasons = Socks5Drop.entries.filter { dropPackets[it.ordinal] > 0 }
                .joinToString(",") { "${it.field}=${dropPackets[it.ordinal]}" }
            return if (protocol == "udp") {
                "traffic: local received ${packets[0]} datagrams/${bytes[0]}B; submitted to local frpc " +
                    "${packets[1]} datagrams/${frpcTxPayloadBytes}B payload; received from local frpc ${packets[2]} datagrams/" +
                    "${frpcRxPayloadBytes}B decoded payload; returned to local app ${packets[3]} datagrams/${bytes[3]}B; " +
                    "payload sizes tx=$txMin..${txMax}B rx=$rxMin..${rxMax}B; " +
                    "observed drops $loss${if (reasons.isEmpty()) "" else " ($reasons)"} (not remote delivery confirmation)"
            } else "traffic: submitted to local frpc ${tcpFrpcTxBytes}B; returned to local app ${tcpLocalTxBytes}B"
        }
    }
}
