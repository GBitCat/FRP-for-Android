package com.frp.app.data

import android.content.Context
import com.frp.app.utils.DnsUtils
import java.io.File

class ConfigGenerator(private val context: Context) {

    companion object {
        /** frpc 官方默认 STUN 服务器（仅用于 UI 预览，运行时会被解析/探测结果替换） */
        private const val DEFAULT_STUN_SERVER = "stun.easyvoip.com:3478"

        /** 全部候选探测失败时的兜底（已实测可达的 Bilibili STUN IP） */
        private const val FALLBACK_STUN_SERVER = "106.12.251.31:3478"

        /** STUN 候选优先级：frpc 官方默认 → 国内 Bilibili → 已验证可达 IP */
        private val STUN_CANDIDATES = listOf(
            "stun.easyvoip.com" to 3478,
            "stun.chat.bilibili.com" to 3478,
            "106.12.251.31" to 3478,
            "77.72.169.210" to 3478,
        )

    fun generateProxyConfig(config: FrpConfig): String {
        return buildString {
            when (config.protocol.lowercase()) {
                "stcp", "sudp", "xtcp" -> {
                    if (config.isVisitor()) {
                        appendLine("[[visitors]]")
                        appendLine("name = \"${config.name}\"")
                        appendLine("type = \"${config.protocol}\"")
                        appendLine("serverName = \"${config.serverName ?: ""}\"")
                        config.secretKey?.takeIf { it.isNotBlank() }?.let {
                            appendLine("secretKey = \"$it\"")
                        }
                        if (config.bindPort != -1) {
                            appendLine("bindAddr = \"${config.bindAddr}\"")
                        }
                        appendLine("bindPort = ${config.bindPort}")
                        if (config.protocol == "xtcp") {
                            // 保持 P2P 隧道常开：frpc 启动即打洞并定期检测，
                            // 避免连接到达时才冷启动打洞（2~4s）导致回落 STCP
                            appendLine("keepTunnelOpen = true")
                            if (config.useFallback && config.fallbackTo.isNotBlank()) {
                                appendLine("fallbackTo = \"${config.fallbackTo}\"")
                                appendLine("fallbackTimeoutMs = ${config.fallbackTimeoutMs}")
                            }
                        }
                    } else {
                        appendLine("[[proxies]]")
                        appendLine("name = \"${config.name}\"")
                        appendLine("type = \"${config.protocol}\"")
                        appendLine("localIP = \"${config.localIp}\"")
                        appendLine("localPort = ${config.localPort}")
                        config.secretKey?.takeIf { it.isNotBlank() }?.let {
                            appendLine("secretKey = \"$it\"")
                        }
                    }
                }
                else -> {
                    appendLine("[[proxies]]")
                    appendLine("name = \"${config.name}\"")
                    appendLine("type = \"${config.protocol}\"")
                    appendLine("localIP = \"${config.localIp}\"")
                    appendLine("localPort = ${config.localPort}")
                    if (config.remotePort > 0) {
                        appendLine("remotePort = ${config.remotePort}")
                    }
                }
            }

            // 传输加密/压缩：TOML 子表必须紧跟所属 [[visitors]]/[[proxies]] 块
            if (config.useEncryption || config.useCompression) {
                appendLine()
                appendLine(if (config.isVisitor()) "[visitors.transport]" else "[proxies.transport]")
                appendLine("useEncryption = ${config.useEncryption}")
                appendLine("useCompression = ${config.useCompression}")
            }
        }
    }

    /**
     * 生成完整 frpc 配置：全局服务器连接配置 + 应用代理/visitor 配置拼接。
     *
     * [stunServer] 为应用层解析/探测后的 STUN 服务器（IP:port），
     * [serverAddrOriginal] 为原始 serverAddr 域名（用于在生成文件中加注释，便于调试）。
     * 此方法本身不做网络调用，可在 UI 线程安全使用（编辑页预览）。
     */
    /**
     * 全局服务器连接配置段（serverAddr / token / STUN / transport）。
     */
    private fun generateGlobalConfig(
        server: ServerConfig,
        stunServer: String = DEFAULT_STUN_SERVER,
        serverAddrOriginal: String? = null
    ): String {
        return buildString {
            if (serverAddrOriginal != null && serverAddrOriginal != server.serverAddr) {
                appendLine("# serverAddr resolved from \"$serverAddrOriginal\"")
            }
            appendLine("serverAddr = \"${server.serverAddr}\"")
            appendLine("serverPort = ${server.serverPort}")
            server.token.takeIf { it.isNotBlank() }?.let {
                appendLine("auth.token = \"$it\"")
            }
            // STUN server：应用层解析 + 探测后的 IP（绕过 Android DNS 限制）
            appendLine("natHoleStunServer = \"$stunServer\"")
            appendLine()
            // 连接 frps 的 transport 配置（与对端 frpc 保持一致）
            appendLine("transport.protocol = \"${server.protocol}\"")
            appendLine("transport.tcpMux = ${server.tcpMux}")
            appendLine("transport.heartbeatInterval = ${server.heartbeatInterval}")
            appendLine("transport.heartbeatTimeout = ${server.heartbeatTimeout}")
            appendLine("transport.tcpMuxKeepaliveInterval = ${server.tcpMuxKeepaliveInterval}")
            appendLine()
        }
    }

    /**
     * 生成服务端配置完整预览：全局段 + 隶属于该 server 的应用配置拼接。
     * [appConfigs] 应传入该 server 归属的应用配置（serverId 匹配或为空）。
     */
    fun generateServerConfigPreview(server: ServerConfig, appConfigs: List<FrpConfig>): String =
        if (appConfigs.isEmpty()) {
            generateGlobalConfig(server)
        } else {
            generateAllConfig(server, appConfigs)
        }

    /**
     * 生成单个配置的完整 frpc 配置（编辑页预览用）。
     */
    fun generateFullConfig(
        server: ServerConfig,
        config: FrpConfig,
        linkedConfig: FrpConfig? = null,
        stunServer: String = DEFAULT_STUN_SERVER,
        serverAddrOriginal: String? = null
    ): String {
        return buildString {
            append(generateGlobalConfig(server, stunServer, serverAddrOriginal))
            if (linkedConfig != null) {
                appendLine("# Fallback STCP visitor")
                append(generateProxyConfig(linkedConfig))
                appendLine()
                appendLine("# Primary XTCP visitor")
                append(generateProxyConfig(config))
            } else {
                append(generateProxyConfig(config))
            }
        }
    }

    /**
     * 拼接所有已启用配置生成统一 frpc TOML：
     * 一次启动服务端连接即可加载全部应用配置。
     */
    fun generateAllConfig(
        server: ServerConfig,
        configs: List<FrpConfig>,
        stunServer: String = DEFAULT_STUN_SERVER,
        serverAddrOriginal: String? = null
    ): String {
        return buildString {
            append(generateGlobalConfig(server, stunServer, serverAddrOriginal))
            // 同分组配置连续排列（组内主配置在前），无分组配置排在后面
            val ordered = configs.sortedWith(
                compareBy<FrpConfig> { if (it.isInGroup()) 0 else 1 }
                    .thenBy { if (it.isInGroup()) it.groupId else Long.MAX_VALUE }
                    .thenByDescending { it.isGroupPrimary }
            )
            ordered.forEachIndexed { index, config ->
                if (index > 0) appendLine()
                appendLine("# Config: ${config.name} (${config.protocol})")
                append(generateProxyConfig(config))
            }
        }
    }

    fun createLinkedStcpConfig(xtcpConfig: FrpConfig): FrpConfig {
        val stcpName = "${xtcpConfig.name}-stcp"
        return FrpConfig(
            name = stcpName,
            localIp = xtcpConfig.localIp,
            localPort = xtcpConfig.localPort,
            protocol = "stcp",
            role = "visitor",
            secretKey = xtcpConfig.secretKey,
            serverName = xtcpConfig.stcpServerName.ifBlank { xtcpConfig.serverName?.replace("xtcp", "stcp") ?: "" },
            bindPort = -1,
            bindAddr = "",
            useEncryption = xtcpConfig.useEncryption,
            useCompression = xtcpConfig.useCompression,
            serverId = xtcpConfig.serverId
        )
    }
    }

    /**
     * 启动时生成最终 TOML：
     * 1. serverAddr 若为域名 → 应用层解析为 IP 写入；
     * 2. 每次启动逐个解析 + UDP 探测 STUN 候选，取第一个当前可达的；
     *    全部不可达则重新解析首选候选，最后回退到已知可用 IP。
     */
    /**
     * 保存拼接了全部已启用配置的统一 TOML（frpc_all.toml），
     * 一次启动即可使用所有应用配置。
     */
    fun saveAllConfigFile(server: ServerConfig, configs: List<FrpConfig>): File {
        val resolved = resolveConnection(server)
        val configContent = generateAllConfig(
            resolved.first, configs,
            stunServer = resolved.second,
            serverAddrOriginal = server.serverAddr
        )
        val configFile = context.getFileStreamPath("frpc_all.toml")
        configFile.writeText(configContent)
        return configFile
    }

    private fun resolveConnection(server: ServerConfig): Pair<ServerConfig, String> {
        // 1. serverAddr 域名 → IP（已是 IP 则原样保留）
        val originalAddr = server.serverAddr.trim()
        val resolvedAddr = originalAddr.takeIf { it.isNotBlank() }
            ?.let { DnsUtils.resolveHost(it) ?: it }
            ?: originalAddr

        // 2. STUN：逐个解析 + 探测，返回第一个可达的 IP:port
        val resolvedStun: String? = DnsUtils.findBestStunServer(STUN_CANDIDATES)
            ?.let { (ip, port) -> "$ip:$port" }
        val stun = resolvedStun
            // 3. 全部不可达：重新解析首选候选（frpc 官方默认）
            ?: run {
                val first = STUN_CANDIDATES.first()
                DnsUtils.resolveHost(first.first)?.let { "${it}:${first.second}" }
            }
            // 4. 仍失败：回退到已验证可达的 IP
            ?: FALLBACK_STUN_SERVER

        return server.copy(serverAddr = resolvedAddr) to stun
    }

    fun validateConfig(config: FrpConfig): String? {
        if (config.name.isBlank()) return "Name is required"

        when (config.protocol.lowercase()) {
            "stcp", "sudp", "xtcp" -> {
                if (config.isVisitor()) {
                    if (config.serverName.isNullOrBlank()) return "Server name is required for visitor"
                    if (config.bindPort <= 0 && config.bindPort != -1) return "Bind port is required for visitor"
                } else {
                    if (config.localPort <= 0) return "Local port is required"
                }
            }
            else -> {
                if (config.localPort <= 0) return "Local port is required"
                if (config.remotePort <= 0) return "Remote port is required"
            }
        }

        return null
    }

    fun validateServerConfig(server: ServerConfig): String? {
        if (server.serverAddr.isBlank()) return "Server address is required"
        if (server.serverPort !in 1..65535) return "Server port is invalid"
        return null
    }
}
