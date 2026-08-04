package com.frp.app

import com.frp.app.data.ConfigGenerator
import com.frp.app.data.FrpConfig
import com.frp.app.data.ServerConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ConfigGenerator 纯逻辑单测：TOML 生成结构正确性。
 * 覆盖：visitor/proxy 块、transport 子表归属、加密开关、合并拼接。
 */
class ConfigGeneratorTest {

    private fun xtcpVisitor(
        useEncryption: Boolean = true,
        useCompression: Boolean = true,
        useFallback: Boolean = true
    ) = FrpConfig(
        name = "xtcp_visitor",
        localPort = 0,
        protocol = "xtcp",
        role = "visitor",
        secretKey = "sk",
        serverName = "xtcp_ssh",
        bindPort = 39522,
        bindAddr = "127.0.0.1",
        useEncryption = useEncryption,
        useCompression = useCompression,
        useFallback = useFallback,
        fallbackTo = "stcp_visitor",
        fallbackTimeoutMs = 3000
    )

    private fun stcpVisitor() = FrpConfig(
        name = "stcp_visitor",
        localPort = 0,
        protocol = "stcp",
        role = "visitor",
        secretKey = "sk",
        serverName = "stcp_ssh",
        bindPort = -1
    )

    private fun tcpProxy() = FrpConfig(
        name = "tcp_proxy",
        localIp = "127.0.0.1",
        localPort = 22,
        remotePort = 6000,
        protocol = "tcp",
        role = "server"
    )

    private fun server() = ServerConfig(
        serverAddr = "1.2.3.4",
        serverPort = 7000,
        token = "secret-token"
    )

    @Test
    fun `xtcp visitor emits keepTunnelOpen and transport sub-table`() {
        val out = ConfigGenerator.generateProxyConfig(xtcpVisitor())
        assertTrue(out.contains("[[visitors]]"))
        assertTrue(out.contains("keepTunnelOpen = true"))
        assertTrue(out.contains("fallbackTo = \"stcp_visitor\""))
        assertTrue(out.contains("fallbackTimeoutMs = 3000"))
        // transport 子表紧跟 visitor 块（在下一个块之前）
        val visitorsIdx = out.indexOf("[[visitors]]")
        val transportIdx = out.indexOf("[visitors.transport]")
        assertTrue(visitorsIdx >= 0 && transportIdx > visitorsIdx)
        assertTrue(out.contains("useEncryption = true"))
        assertTrue(out.contains("useCompression = true"))
    }

    @Test
    fun `xtcp visitor without encryption emits no transport sub-table`() {
        val out = ConfigGenerator.generateProxyConfig(xtcpVisitor(useEncryption = false, useCompression = false))
        assertFalse(out.contains("[visitors.transport]"))
        assertFalse(out.contains("useEncryption"))
    }

    @Test
    fun `stcp visitor with bindPort -1 omits bindAddr`() {
        val out = ConfigGenerator.generateProxyConfig(stcpVisitor())
        assertTrue(out.contains("name = \"stcp_visitor\""))
        assertTrue(out.contains("bindPort = -1"))
        assertFalse(out.contains("bindAddr"))
    }

    @Test
    fun `tcp proxy emits localIP localPort remotePort`() {
        val out = ConfigGenerator.generateProxyConfig(tcpProxy())
        assertTrue(out.contains("[[proxies]]"))
        assertTrue(out.contains("localIP = \"127.0.0.1\""))
        assertTrue(out.contains("localPort = 22"))
        assertTrue(out.contains("remotePort = 6000"))
    }

    @Test
    fun `all configs are combined with global section`() {
        val out = ConfigGenerator.generateAllConfig(server(), listOf(xtcpVisitor(), stcpVisitor(), tcpProxy()))
        // 全局段
        assertTrue(out.contains("serverAddr = \"1.2.3.4\""))
        assertTrue(out.contains("serverPort = 7000"))
        assertTrue(out.contains("auth.token = \"secret-token\""))
        assertTrue(out.contains("natHoleStunServer"))
        assertTrue(out.contains("transport.protocol = \"tcp\""))
        assertTrue(out.contains("transport.tcpMux = true"))
        assertTrue(out.contains("transport.heartbeatTimeout = 90"))
        // 三个配置块
        assertEquals(2, Regex("\\[\\[visitors\\]\\]").findAll(out).count())
        assertEquals(1, Regex("\\[\\[proxies\\]\\]").findAll(out).count())
        // 每个块有注释分隔
        assertTrue(out.contains("# Config: xtcp_visitor (xtcp)"))
        assertTrue(out.contains("# Config: tcp_proxy (tcp)"))
        // 排序：visitors 在前（xtcp 先于 stcp，按列表顺序）
        assertTrue(out.indexOf("name = \"xtcp_visitor\"") < out.indexOf("name = \"stcp_visitor\""))
    }

    @Test
    fun `server transport settings are configurable`() {
        val customServer = server().copy(
            protocol = "kcp",
            tcpMux = false,
            heartbeatInterval = 60,
            heartbeatTimeout = 120,
            tcpMuxKeepaliveInterval = 60
        )
        val out = ConfigGenerator.generateAllConfig(customServer, listOf(tcpProxy()))
        assertTrue(out.contains("transport.protocol = \"kcp\""))
        assertTrue(out.contains("transport.tcpMux = false"))
        assertTrue(out.contains("transport.heartbeatInterval = 60"))
        assertTrue(out.contains("transport.heartbeatTimeout = 120"))
        assertTrue(out.contains("transport.tcpMuxKeepaliveInterval = 60"))
    }

    @Test
    fun `createLinkedStcpConfig strips xtcp naming rule suffix`() {
        val xtcp = xtcpVisitor().copy(name = "linux-ssh-xtcp", serverName = "linux-ssh-xtcp")
        val stcp = ConfigGenerator.createLinkedStcpConfig(xtcp)
        assertEquals("linux-ssh-stcp", stcp.name)
        assertEquals("linux-ssh-stcp", stcp.serverName)
        assertEquals(-1, stcp.bindPort)
    }

    @Test
    fun `createLinkedStcpConfig keeps plain names unchanged`() {
        val stcp = ConfigGenerator.createLinkedStcpConfig(xtcpVisitor())
        assertEquals("xtcp_visitor-stcp", stcp.name)
        assertEquals("stcp_ssh", stcp.serverName)
    }
}
