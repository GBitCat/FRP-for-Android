package com.frp.app.utils

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.security.SecureRandom

/**
 * 应用层 DNS 解析与 STUN 服务器探测工具。
 *
 * frpc（Go 静态二进制）在 Android 上无法解析域名（读 /etc/resolv.conf 里的 [::1]:53 失败），
 * 但 Android 应用进程自身的解析走系统 netd，完全正常。
 * 因此：应用层先把域名解析成 IP 再写入 frpc TOML，即可绕过该限制。
 */
object DnsUtils {

    private val IPV4_REGEX = Regex(
        """^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$"""
    )

    /** 判断 host 是否是 IP 字面量（IPv4 或 IPv6），避免触发 DNS 查询 */
    fun isIpLiteral(host: String): Boolean {
        val h = host.trim().removePrefix("[").removeSuffix("]")
        return h.contains(":") || IPV4_REGEX.matches(h)
    }

    /** IPv6 加方括号，IPv4 原样返回 */
    fun formatIpLiteral(ip: String): String =
        if (ip.contains(":")) "[$ip]" else ip

    /**
     * 解析域名 → IP 字面量（含 IPv6 方括号）。已是 IP 则原样返回。
     * 失败返回 null，调用方自行回退。
     */
    fun resolveHost(host: String): String? {
        val h = host.trim().removePrefix("[").removeSuffix("]")
        if (h.isEmpty()) return null
        if (isIpLiteral(h)) return formatIpLiteral(h)
        return try {
            val addr = InetAddress.getByName(h) ?: return null
            addr.hostAddress?.let { formatIpLiteral(it) }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * 发送标准 STUN Binding Request，探测 host:port 是否可用（UDP）。
     * 收到 0x0101（Binding Success Response）视为可用。
     */
    fun probeStun(host: String, port: Int, timeoutMs: Int = 1000): Boolean {
        return try {
            DatagramSocket().use { socket ->
                socket.soTimeout = timeoutMs
                val txid = ByteArray(12).also { SecureRandom().nextBytes(it) }
                val request = ByteBuffer.allocate(20)
                    .putShort(0x0001)          // Binding Request
                    .putShort(0)               // length = 0
                    .putInt(0x2112A442)        // magic cookie
                    .put(txid)
                    .array()
                val dst = InetAddress.getByName(host)
                socket.send(DatagramPacket(request, request.size, dst, port))
                val buf = ByteArray(256)
                val resp = DatagramPacket(buf, buf.size)
                socket.receive(resp)
                resp.length >= 20 &&
                    (buf[0].toInt() and 0xFF) == 0x01 &&
                    (buf[1].toInt() and 0xFF) == 0x01
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * 按优先级逐个解析 + 探测 STUN 候选（host -> IP -> UDP 可用性），
     * 返回第一个可达的 "IP:port"（host 为 IP 字面量）；全部失败返回 null。
     */
    fun findBestStunServer(
        candidates: List<Pair<String, Int>>,
        timeoutMs: Int = 1000
    ): Pair<String, Int>? {
        for ((host, port) in candidates) {
            val ip = resolveHost(host) ?: continue
            if (probeStun(ip, port, timeoutMs)) {
                return ip to port
            }
        }
        return null
    }
}
