package com.frp.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.frp.app.data.ConfigGenerator
import com.frp.app.data.FrpConfig
import com.frp.app.data.ServerConfig
import com.frp.app.ui.theme.FRPAndroidTheme
import com.frp.app.viewmodel.MainViewModel

class ConfigEditActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val configId = intent.getLongExtra("config_id", -1)
        setContent {
            FRPAndroidTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ConfigEditScreen(
                        configId = if (configId != -1L) configId else null,
                        onBack = { finish() },
                        onSave = { finish() }
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConfigEditScreen(
    configId: Long?,
    onBack: () -> Unit,
    onSave: () -> Unit,
    viewModel: MainViewModel = viewModel()
) {
    val context = LocalContext.current
    val configGenerator = remember { ConfigGenerator(context) }
    val isEditing = configId != null
    val serverConfig by viewModel.serverConfig.collectAsState(initial = null)
    var serverDropdownExpanded by remember { mutableStateOf(false) }
    
    // 表单状态
    var name by remember { mutableStateOf("") }
    var localIp by remember { mutableStateOf("127.0.0.1") }
    var localPort by remember { mutableStateOf("") }
    var remotePort by remember { mutableStateOf("") }
    var protocol by remember { mutableStateOf("tcp") }
    
    // STCP/XTCP 特有状态
    var role by remember { mutableStateOf("server") }
    var secretKey by remember { mutableStateOf("") }
    var serverName by remember { mutableStateOf("") }
    var bindPort by remember { mutableStateOf("9002") }
    var bindAddr by remember { mutableStateOf("127.0.0.1") }
    var showSecretKey by remember { mutableStateOf(false) }
    var serverId by remember { mutableStateOf("") }
    var editGroupName by remember { mutableStateOf("") }
    
    // 传输加密/压缩（需与对端 frpc 配置一致）
    var useEncryption by remember { mutableStateOf(false) }
    var useCompression by remember { mutableStateOf(false) }
    
    // XTCP 回落配置
    var useFallback by remember { mutableStateOf(false) }
    var fallbackTimeoutMs by remember { mutableStateOf("3000") }
    var fallbackTo by remember { mutableStateOf("") }
    
    // STCP Fallback 独立配置状态
    var stcpName by remember { mutableStateOf("") }
    var stcpSecretKey by remember { mutableStateOf("") }
    var stcpServerName by remember { mutableStateOf("") }
    var stcpBindPort by remember { mutableStateOf("-1") }
    var stcpBindAddr by remember { mutableStateOf("127.0.0.1") }
    var useCustomStcp by remember { mutableStateOf(false) }  // 是否自定义STCP配置
    var useNamingRule by remember { mutableStateOf(true) }   // XTCP 固定规则：名称自动追加 -xtcp 后缀
    var serverNameCustomized by remember { mutableStateOf(false) } // Server Proxy Name 是否被手动修改
    var showPeerConfigDialog by remember { mutableStateOf(false) }
    var showGroupNameDialog by remember { mutableStateOf(false) }
    var pendingSaveConfig by remember { mutableStateOf<FrpConfig?>(null) }
    var originalConfig by remember { mutableStateOf<FrpConfig?>(null) }
    var groupName by remember { mutableStateOf("") }
    
    // 加载现有配置
    LaunchedEffect(configId) {
        if (configId != null) {
            val config = viewModel.getConfigById(configId)
            if (config != null) {
                originalConfig = config
                // 固定规则：名称以 -xtcp 结尾时拆出基础名并开启规则；否则保持原名（规则关闭）
                if (config.protocol.lowercase() == "xtcp" && config.name.endsWith("-xtcp")) {
                    name = config.name.removeSuffix("-xtcp")
                    useNamingRule = true
                } else {
                    name = config.name
                    useNamingRule = config.protocol.lowercase() == "xtcp"
                }
                serverNameCustomized = false
                localIp = config.localIp
                localPort = config.localPort.toString()
                remotePort = config.remotePort.toString()
                protocol = config.protocol
                role = config.role
                secretKey = config.secretKey ?: ""
                serverName = config.serverName ?: ""
                bindPort = config.bindPort.toString()
                bindAddr = config.bindAddr
                serverId = config.serverId
                editGroupName = config.groupName
                useEncryption = config.useEncryption
                useCompression = config.useCompression
                android.util.Log.d("ConfigEdit", "Loading - useFallback: ${config.useFallback}, fallbackTo: ${config.fallbackTo}")
                useFallback = config.useFallback
                useCustomStcp = config.useCustomStcp
                stcpName = config.stcpName
                stcpSecretKey = config.stcpSecretKey
                stcpServerName = config.stcpServerName
                stcpBindPort = config.stcpBindPort.toString()
                stcpBindAddr = config.stcpBindAddr
                fallbackTimeoutMs = config.fallbackTimeoutMs.toString()
                fallbackTo = config.fallbackTo
            }
        }
    }
    
    
    
    val isSecretProtocol = FrpConfig.needsSecretKey(protocol)
    val isVisitor = role == "visitor"
    val supportsFallback = FrpConfig.supportsFallback(protocol)
    
    // 自动生成名称
    val autoStcpName = "${name.ifBlank { "service" }}-stcp"
    
    // XTCP 固定规则后的有效名称（如 linux-ssh → linux-ssh-xtcp）
    val effectiveName = if (protocol.lowercase() == "xtcp" && useNamingRule) {
        val base = name.trim()
        if (base.endsWith("-xtcp")) base else if (base.isBlank()) "" else "$base-xtcp"
    } else {
        name
    }
    
    // Server Proxy Name 默认跟随固定规则后的命名；用户手动修改后不再自动覆盖
    LaunchedEffect(protocol, useNamingRule, effectiveName) {
        if (!serverNameCustomized && protocol.lowercase() == "xtcp") {
            serverName = effectiveName
        }
    }
    
    // 初始化STCP配置（使用XTCP的值）
    LaunchedEffect(name, secretKey, serverName, bindAddr) {
        if (!useCustomStcp) {
            stcpName = autoStcpName
            stcpSecretKey = secretKey
            stcpServerName = serverName.replace("xtcp", "stcp")
            stcpBindAddr = bindAddr
        }
    }
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (isEditing) "Edit Configuration" else "New Configuration") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    TextButton(
                        onClick = {
                            // 基于原配置 copy：编辑时自动保留分组/启用/运行状态/时间戳等字段，
                            // 避免手工构造遗漏（历史 bug：分组字段被清零）
                            val config = (originalConfig ?: FrpConfig(name = name, localPort = 0)).copy(
                                id = configId ?: 0,
                                name = effectiveName,
                                localIp = localIp,
                                localPort = localPort.toIntOrNull() ?: 0,
                                remotePort = remotePort.toIntOrNull() ?: 0,
                                protocol = protocol,
                                role = role,
                                secretKey = secretKey.ifBlank { null },
                                serverName = serverName.ifBlank { null },
                                bindPort = bindPort.toIntOrNull() ?: 0,
                                bindAddr = bindAddr,
                                useEncryption = useEncryption,
                                useCompression = useCompression,
                                serverId = serverId.ifEmpty { serverConfig?.serverId ?: "" },
                                groupName = if (originalConfig?.isInGroup() == true) editGroupName else (originalConfig?.groupName ?: ""),
                                useFallback = useFallback,
                                fallbackTo = if (useFallback) {
                                    if (useCustomStcp) {
                                        stcpName.ifBlank { autoStcpName }
                                    } else {
                                        // 非自定义：保留原有回落目标（避免主配置改名破坏 fallbackTo）
                                        originalConfig?.fallbackTo?.takeIf { it.isNotBlank() }
                                            ?: autoStcpName
                                    }
                                } else "",
                                fallbackTimeoutMs = fallbackTimeoutMs.toIntOrNull() ?: 3000,
                                useCustomStcp = useCustomStcp,
                                stcpName = stcpName.ifBlank { autoStcpName },
                                stcpSecretKey = stcpSecretKey.ifBlank { secretKey },
                                stcpServerName = stcpServerName.ifBlank { serverName.replace("xtcp", "stcp") },
                                stcpBindPort = stcpBindPort.toIntOrNull() ?: -1,
                                stcpBindAddr = stcpBindAddr
                            )
                            
                            val error = configGenerator.validateConfig(config)
                            if (error != null) {
                                Toast.makeText(context, error, Toast.LENGTH_SHORT).show()
                                return@TextButton
                            }
                            
                            if (isEditing) {
                                viewModel.updateConfig(config)
                                // 主配置保存后联动同步 linked STCP，保证生成文件与预览一致；
                                // 自定义 STCP Name 变化时先重命名实际子配置再同步
                                if (config.isVisitor() && config.supportsFallback() && config.useFallback) {
                                    val oldLinked = originalConfig?.fallbackTo
                                    val newLinked = if (useCustomStcp) {
                                        stcpName.ifBlank { autoStcpName }
                                    } else {
                                        originalConfig?.fallbackTo?.takeIf { it.isNotBlank() } ?: autoStcpName
                                    }
                                    if (useCustomStcp && !oldLinked.isNullOrBlank() && oldLinked != newLinked) {
                                        viewModel.renameAndSyncStcp(oldLinked, newLinked, config)
                                    } else {
                                        viewModel.syncLinkedStcp(config)
                                    }
                                }
                                // 分组重命名：同步到组内全部配置
                                val origGroupId = originalConfig?.groupId
                                if (origGroupId != null && origGroupId > 0 &&
                                    editGroupName != originalConfig?.groupName
                                ) {
                                    viewModel.updateGroupName(origGroupId, editGroupName)
                                }
                                Toast.makeText(context, "Configuration updated", Toast.LENGTH_SHORT).show()
                                onSave()
                            } else {
                                if (useFallback && supportsFallback && isVisitor) {
                                    // 保存config引用供dialog使用
                                    pendingSaveConfig = config
                                    showGroupNameDialog = true
                                } else {
                                    viewModel.addConfig(config)
                                    Toast.makeText(context, "Configuration added", Toast.LENGTH_SHORT).show()
                                    onSave()
                                }
                            }
                        }
                    ) {
                        Text("Save")
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(16.dp)
                .verticalScroll(rememberScrollState())
        ) {
            // 基本信息
            Text(
                text = "Basic Information",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            
            // 隶属 Server 选择（serverId 仅用于归属标识，不参与 TOML）
            ExposedDropdownMenuBox(
                expanded = serverDropdownExpanded,
                onExpandedChange = { serverDropdownExpanded = it }
            ) {
                OutlinedTextField(
                    value = serverConfig?.let { "${it.name} (${it.serverId})" } ?: "No server configured",
                    onValueChange = {},
                    readOnly = true,
                    label = { Text("Belongs to Server") },
                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = serverDropdownExpanded) },
                    modifier = Modifier.fillMaxWidth().menuAnchor()
                )
                ExposedDropdownMenu(
                    expanded = serverDropdownExpanded,
                    onDismissRequest = { serverDropdownExpanded = false }
                ) {
                    serverConfig?.let { server ->
                        DropdownMenuItem(
                            text = { Text("${server.name} (${server.serverId})") },
                            onClick = {
                                serverId = server.serverId
                                serverDropdownExpanded = false
                            }
                        )
                    }
                }
            }
            
            // 分组名称（仅分组内配置可修改，保存后同步到组内全部配置）
            if (originalConfig?.isInGroup() == true) {
                Spacer(modifier = Modifier.height(12.dp))
                OutlinedTextField(
                    value = editGroupName,
                    onValueChange = { editGroupName = it },
                    label = { Text("Group Name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // 服务器连接配置已移至主界面
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                )
            ) {
                Row(
                    modifier = Modifier.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Default.Dns,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Server connection (address / port / token) is configured on the main screen.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // 协议选择
            Text(
                text = "Protocol",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                listOf("tcp", "udp", "http", "https").forEach { proto ->
                    FilterChip(
                        selected = protocol == proto,
                        onClick = { protocol = proto },
                        label = { Text(proto.uppercase()) },
                        modifier = Modifier.weight(1f)
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(8.dp))
            
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                listOf("stcp", "sudp", "xtcp").forEach { proto ->
                    FilterChip(
                        selected = protocol == proto,
                        onClick = { protocol = proto },
                        label = { Text(proto.uppercase()) },
                        modifier = Modifier.weight(1f),
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = MaterialTheme.colorScheme.tertiaryContainer
                        )
                    )
                }
            }
            
            // 非 secret 协议（tcp 等）在此命名；secret 协议的名称在下方 Settings 块内
            AnimatedVisibility(visible = !isSecretProtocol) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Configuration Name *") },
                    placeholder = { Text("e.g., xtcp-visitor") },
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(16.dp))
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // STCP/XTCP 特有配置
            AnimatedVisibility(visible = isSecretProtocol) {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.tertiaryContainer.copy(alpha = 0.3f)
                    )
                ) {
                    Column(
                        modifier = Modifier.padding(16.dp)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "${protocol.uppercase()} Settings",
                                style = MaterialTheme.typography.titleMedium
                            )
                            // XTCP 固定规则开关：开启后名称自动追加 -xtcp 后缀
                            if (protocol.lowercase() == "xtcp") {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = "Fixed Rule",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                    Switch(
                                        checked = useNamingRule,
                                        onCheckedChange = { useNamingRule = it }
                                    )
                                }
                            }
                        }
                        Text(
                            text = if (protocol.lowercase() == "xtcp" && useNamingRule) {
                                "Auto suffix: -xtcp appended to the name"
                            } else {
                                "Name is used as-is"
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 4.dp, bottom = 12.dp)
                        )
                        
                        // 主配置名（XTCP Name / STCP Name，与 STCP Fallback 的 STCP Name 对应）
                        OutlinedTextField(
                            value = name,
                            onValueChange = { name = it },
                            label = { Text("${protocol.uppercase()} Name") },
                            placeholder = { Text("e.g., linux-ssh") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                            suffix = if (protocol.lowercase() == "xtcp" && useNamingRule) ({
                                Text(
                                    text = "-xtcp",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.padding(end = 4.dp)
                                )
                            }) else null
                        )
                        
                        Spacer(modifier = Modifier.height(12.dp))
                        
                        // 角色选择
                        Text(
                            text = "Role",
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(bottom = 4.dp)
                        )
                        
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            FilterChip(
                                selected = role == "server",
                                onClick = { role = "server" },
                                label = { Text("Server (Expose)") },
                                modifier = Modifier.weight(1f)
                            )
                            FilterChip(
                                selected = role == "visitor",
                                onClick = { role = "visitor" },
                                label = { Text("Visitor (Access)") },
                                modifier = Modifier.weight(1f)
                            )
                        }
                        
                        Spacer(modifier = Modifier.height(12.dp))
                        
                        // Secret Key
                        OutlinedTextField(
                            value = secretKey,
                            onValueChange = { secretKey = it },
                            label = { Text("Secret Key *") },
                            placeholder = { Text("Shared secret for authentication") },
                            modifier = Modifier.fillMaxWidth(),
                            visualTransformation = if (showSecretKey) VisualTransformation.None else PasswordVisualTransformation(),
                            trailingIcon = {
                                IconButton(onClick = { showSecretKey = !showSecretKey }) {
                                    Icon(
                                        if (showSecretKey) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                                        contentDescription = if (showSecretKey) "Hide" else "Show"
                                    )
                                }
                            }
                        )
                        
                        Spacer(modifier = Modifier.height(16.dp))
                        Divider()
                        Spacer(modifier = Modifier.height(8.dp))
                        
                        Text(
                            text = "Transport Encryption / Compression",
                            style = MaterialTheme.typography.titleSmall,
                            modifier = Modifier.padding(bottom = 4.dp)
                        )
                        Text(
                            text = "Must match the peer frpc transport settings (XTCP P2P requires both ends identical)",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(bottom = 4.dp)
                        )
                        
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Encryption", style = MaterialTheme.typography.bodyMedium)
                            Switch(
                                checked = useEncryption,
                                onCheckedChange = { useEncryption = it }
                            )
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Compression", style = MaterialTheme.typography.bodyMedium)
                            Switch(
                                checked = useCompression,
                                onCheckedChange = { useCompression = it }
                            )
                        }
                        
                        Spacer(modifier = Modifier.height(12.dp))
                        
                        // Visitor 特有配置
                        AnimatedVisibility(visible = isVisitor) {
                            Column {
                                OutlinedTextField(
                                    value = serverName,
                                    onValueChange = {
                                        serverName = it
                                        serverNameCustomized = true
                                    },
                                    label = { Text("Server Proxy Name *") },
                                    placeholder = { Text("Server proxy name, e.g. xtcp_ssh") },
                                    modifier = Modifier.fillMaxWidth()
                                )
                                Text(
                                    text = "Must match the proxy name on server (e.g. xtcp_ssh, stcp_ssh)",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(top = 2.dp)
                                )
                                
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.spacedBy(16.dp)
                                ) {
                                    OutlinedTextField(
                                        value = bindAddr,
                                        onValueChange = { bindAddr = it },
                                        label = { Text("Bind Address") },
                                        modifier = Modifier.weight(1f)
                                    )
                                    
                                    OutlinedTextField(
                                        value = bindPort,
                                        onValueChange = { bindPort = it },
                                        label = { Text("Bind Port") },
                                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                        modifier = Modifier.weight(1f)
                                    )
                                }
                            }
                        }
                        
                        // Server 特有配置
                        AnimatedVisibility(visible = !isVisitor) {
                            Column {
                                OutlinedTextField(
                                    value = localIp,
                                    onValueChange = { localIp = it },
                                    label = { Text("Local IP") },
                                    modifier = Modifier.fillMaxWidth()
                                )
                                
                                Spacer(modifier = Modifier.height(12.dp))
                                
                                OutlinedTextField(
                                    value = localPort,
                                    onValueChange = { localPort = it },
                                    label = { Text("Local Port *") },
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                    modifier = Modifier.fillMaxWidth()
                                )
                            }
                        }
                        // XTCP 回落配置
                        AnimatedVisibility(visible = supportsFallback && isVisitor) {
                            Column {
                                Spacer(modifier = Modifier.height(16.dp))
                                Divider()
                                Spacer(modifier = Modifier.height(16.dp))
                                
                                // 启用回落开关
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column {
                                        Text(
                                            text = "Fallback to STCP",
                                            style = MaterialTheme.typography.titleMedium
                                        )
                                        Text(
                                            text = "When XTCP P2P fails, use STCP relay",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                    Switch(
                                        checked = useFallback,
                                        onCheckedChange = {
                                            useFallback = it
                                            // 启用回落时默认使用自动生成模式
                                            if (it) useCustomStcp = false
                                        }
                                    )
                                }
                                
                                // Fallback超时
                                AnimatedVisibility(visible = useFallback) {
                                    Column {
                                        Spacer(modifier = Modifier.height(12.dp))
                                        OutlinedTextField(
                                            value = fallbackTimeoutMs,
                                            onValueChange = { fallbackTimeoutMs = it },
                                            label = { Text("Fallback Timeout (ms)") },
                                            placeholder = { Text("200") },
                                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                            modifier = Modifier.fillMaxWidth()
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // STCP Fallback 独立配置框（仅在XTCP + Visitor + Fallback时显示）
            AnimatedVisibility(visible = supportsFallback && isVisitor && useFallback) {
                Column {
                    Spacer(modifier = Modifier.height(16.dp))
                    
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.secondaryContainer.copy(alpha = 0.5f)
                        )
                    ) {
                        Column(
                            modifier = Modifier.padding(16.dp)
                        ) {
                            // 标题和自定义开关
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column {
                                    Text(
                                        text = "STCP Fallback Visitor",
                                        style = MaterialTheme.typography.titleMedium
                                    )
                                    Text(
                                        text = "Fallback target configuration",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                                Switch(
                                    checked = useCustomStcp,
                                    onCheckedChange = { useCustomStcp = it }
                                )
                            }
                            
                            Text(
                                text = if (useCustomStcp) "Custom configuration" else "Auto (uses XTCP settings)",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(bottom = 12.dp)
                            )
                            
                            // STCP配置字段
                            AnimatedVisibility(visible = useCustomStcp) {
                                Column {
                                    OutlinedTextField(
                                        value = stcpName,
                                        onValueChange = { stcpName = it },
                                        label = { Text("STCP Name") },
                                        placeholder = { Text(autoStcpName) },
                                        modifier = Modifier.fillMaxWidth()
                                    )
                                    
                                    Spacer(modifier = Modifier.height(8.dp))
                                    
                                    OutlinedTextField(
                                        value = stcpSecretKey,
                                        onValueChange = { stcpSecretKey = it },
                                        label = { Text("STCP Secret Key") },
                                        placeholder = { Text("Same as XTCP") },
                                        modifier = Modifier.fillMaxWidth(),
                                        visualTransformation = if (showSecretKey) VisualTransformation.None else PasswordVisualTransformation()
                                    )
                                    
                                    Spacer(modifier = Modifier.height(8.dp))
                                    
                                    OutlinedTextField(
                                        value = stcpServerName,
                                        onValueChange = { stcpServerName = it },
                                        label = { Text("STCP Server Name") },
                                        placeholder = { Text("Same as XTCP") },
                                        modifier = Modifier.fillMaxWidth()
                                    )
                                    
                                    Spacer(modifier = Modifier.height(8.dp))
                                    
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.spacedBy(16.dp)
                                    ) {
                                        OutlinedTextField(
                                            value = stcpBindAddr,
                                            onValueChange = { stcpBindAddr = it },
                                            label = { Text("STCP Bind Addr") },
                                            modifier = Modifier.weight(1f)
                                        )
                                        
                                        OutlinedTextField(
                                            value = stcpBindPort,
                                            onValueChange = { stcpBindPort = it },
                                            label = { Text("STCP Bind Port") },
                                            placeholder = { Text("-1") },
                                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                            modifier = Modifier.weight(1f)
                                        )
                                    }
                                }
                            }
                            
                            // 自动生成时的提示
                            AnimatedVisibility(visible = !useCustomStcp) {
                                Column {
                                    Divider(modifier = Modifier.padding(vertical = 8.dp))
                                    Text(
                                        text = "Auto-generated STCP config:",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                    Text(
                                        text = "name: $autoStcpName\n" +
                                                "secretKey: ${stcpSecretKey.ifBlank { secretKey.ifBlank { "(from XTCP)" } }}\n" +
                                                "serverName: ${stcpServerName.ifBlank { serverName.replace("xtcp", "stcp") }.ifBlank { "(from XTCP)" }}\n" +
                                                "bindPort: -1",
                                        style = MaterialTheme.typography.bodySmall.copy(
                                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
                                        ),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(top = 4.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            }
            
            // 普通协议配置
            AnimatedVisibility(visible = !isSecretProtocol) {
                Column {
                    Text(
                        text = "Local Settings",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(bottom = 8.dp)
                    )
                    
                    OutlinedTextField(
                        value = localIp,
                        onValueChange = { localIp = it },
                        label = { Text("Local IP") },
                        modifier = Modifier.fillMaxWidth()
                    )
                    
                    Spacer(modifier = Modifier.height(16.dp))
                    
                    OutlinedTextField(
                        value = localPort,
                        onValueChange = { localPort = it },
                        label = { Text("Local Port *") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth()
                    )
                    
                    Spacer(modifier = Modifier.height(16.dp))
                    
                    Text(
                        text = "Remote Settings",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(bottom = 8.dp)
                    )
                    
                    OutlinedTextField(
                        value = remotePort,
                        onValueChange = { remotePort = it },
                        label = { Text("Remote Port *") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            Spacer(modifier = Modifier.height(24.dp))
            
            // 配置预览
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            ) {
                Column(
                    modifier = Modifier.padding(16.dp)
                ) {
                    Text(
                        text = "Configuration Preview",
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(bottom = 8.dp)
                    )
                    
                    val previewStcpConfig = if (useFallback && supportsFallback && isVisitor) {
                        if (useCustomStcp) {
                            FrpConfig(
                                name = stcpName.ifBlank { autoStcpName },
                                protocol = "stcp",
                                role = "visitor",
                                secretKey = stcpSecretKey.ifBlank { secretKey },
                                serverName = stcpServerName.ifBlank { serverName },
                                bindPort = stcpBindPort.toIntOrNull() ?: -1,
                                localPort = 0,
                                bindAddr = stcpBindAddr,
                                useEncryption = useEncryption,
                                useCompression = useCompression,
                                serverId = serverId
                            )
                        } else {
                            val xtcpPreview = FrpConfig(
                                name = effectiveName.ifBlank { "preview" },
                                protocol = "xtcp",
                                role = "visitor",
                                secretKey = secretKey.ifBlank { null },
                                serverName = serverName.ifBlank { null },
                                bindPort = bindPort.toIntOrNull() ?: 9002,
                                localPort = 0,
                                bindAddr = bindAddr,
                                useEncryption = useEncryption,
                                useCompression = useCompression
                            )
                            ConfigGenerator.createLinkedStcpConfig(xtcpPreview)
                        }
                    } else null
                    
                    val previewXtcpConfig = FrpConfig(
                        name = effectiveName.ifBlank { "preview" },
                        localIp = localIp,
                        localPort = localPort.toIntOrNull() ?: 0,
                        remotePort = remotePort.toIntOrNull() ?: 0,
                        protocol = protocol,
                        role = role,
                        secretKey = secretKey.ifBlank { null },
                        serverName = serverName.ifBlank { null },
                        bindPort = bindPort.toIntOrNull() ?: 0,
                        bindAddr = bindAddr,
                        useEncryption = useEncryption,
                        useCompression = useCompression,
                        useFallback = useFallback,
                        fallbackTo = if (useCustomStcp) stcpName.ifBlank { autoStcpName } else autoStcpName,
                        
                                fallbackTimeoutMs = fallbackTimeoutMs.toIntOrNull() ?: 3000,
                                useCustomStcp = useCustomStcp,
                                stcpName = stcpName.ifBlank { autoStcpName },
                                stcpSecretKey = stcpSecretKey.ifBlank { secretKey },
                                stcpServerName = stcpServerName.ifBlank { serverName.replace("xtcp", "stcp") },
                                stcpBindPort = stcpBindPort.toIntOrNull() ?: -1,
                                stcpBindAddr = stcpBindAddr
                    )
                    
                    val previewText = ConfigGenerator.generateFullConfig(
                        serverConfig ?: ServerConfig(serverAddr = "frp.example.com"),
                        previewXtcpConfig,
                        previewStcpConfig
                    )
                    
                    Text(
                        text = previewText,
                        style = MaterialTheme.typography.bodySmall.copy(
                            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    
                    // 推导对端配置：生成目标机器上运行的 frpc 配置
                    if (isSecretProtocol && isVisitor) {
                        Spacer(modifier = Modifier.height(12.dp))
                        OutlinedButton(
                            onClick = { showPeerConfigDialog = true },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Default.ContentCopy, contentDescription = null)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text("Derive Peer Config")
                        }
                    }
                }
            }

    // 推导对端配置弹窗
    if (showPeerConfigDialog) {
        val peerConfigText = derivePeerConfigText(
            xtcpName = effectiveName,
            stcpName = stcpName.ifBlank { autoStcpName },
            secretKey = secretKey,
            stcpSecretKey = stcpSecretKey,
            useEncryption = useEncryption,
            useCompression = useCompression,
            localIp = localIp,
            localPort = localPort
        )
        AlertDialog(
            onDismissRequest = { showPeerConfigDialog = false },
            title = { Text("Peer frpc Config") },
            text = {
                Column {
                    Text(
                        text = "Run this on the target machine. Adjust localIP / localPort to the actual service address.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    SelectionContainer {
                        Text(
                            text = peerConfigText,
                            style = MaterialTheme.typography.bodySmall.copy(
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
                            ),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 320.dp)
                                .verticalScroll(rememberScrollState())
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        copyToClipboard(context, "frpc_peer", peerConfigText)
                        Toast.makeText(context, "Peer config copied", Toast.LENGTH_SHORT).show()
                    }
                ) {
                    Text("Copy")
                }
            },
            dismissButton = {
                TextButton(onClick = { showPeerConfigDialog = false }) {
                    Text("Close")
                }
            }
        )
    }

    // 分组命名对话框
    if (showGroupNameDialog) {
        AlertDialog(
            onDismissRequest = { showGroupNameDialog = false },
            title = { Text("Name this configuration group") },
            text = {
                Column {
                    Text("Enter a name for the XTCP + STCP configuration group:")
                    Spacer(modifier = Modifier.height(8.dp))
                    OutlinedTextField(
                        value = groupName,
                        onValueChange = { groupName = it },
                        label = { Text("Group Name") },
                        placeholder = { Text("e.g., SSH P2P Connection") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showGroupNameDialog = false
                        val groupId = System.currentTimeMillis()
                        val finalGroupName = groupName.ifBlank { "Group $groupId" }
                        
                        // 创建STCP配置
                        val stcpConfig = if (useCustomStcp) {
                            FrpConfig(
                                name = stcpName.ifBlank { autoStcpName },
                                protocol = "stcp",
                                role = "visitor",
                                secretKey = stcpSecretKey.ifBlank { secretKey },
                                serverName = stcpServerName.ifBlank { serverName.replace("xtcp", "stcp") },
                                bindPort = stcpBindPort.toIntOrNull() ?: -1,
                                localPort = 0,
                                bindAddr = stcpBindAddr,
                                useEncryption = useEncryption,
                                useCompression = useCompression,
                                serverId = serverId,
                                groupId = groupId,
                                groupName = finalGroupName,
                                isGroupPrimary = false
                            )
                        } else {
                            ConfigGenerator.createLinkedStcpConfig(pendingSaveConfig!!).copy(
                                groupId = groupId,
                                groupName = finalGroupName,
                                isGroupPrimary = false
                            )
                        }
                        
                        // 创建XTCP配置（主配置）
                        val xtcpConfig = pendingSaveConfig!!.copy(
                            groupId = groupId,
                            groupName = finalGroupName,
                            isGroupPrimary = true
                        )
                        
                        // 保存配置（顺序插入，保证组内顺序）
                        viewModel.addConfigs(listOf(stcpConfig, xtcpConfig))
                        
                        Toast.makeText(context, "Created group: $finalGroupName", Toast.LENGTH_SHORT).show()
                        onSave()
                    }
                ) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { showGroupNameDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }

        }
    }
}

private fun copyToClipboard(context: Context, label: String, text: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText(label, text))
}

/**
 * 推导对端（目标机器）frpc 配置：以 server 角色生成 XTCP + STCP 两个 [[proxies]] 块。
 * localIP / localPort 使用占位值，复制后由用户在目标机器上按实际情况修改。
 */
private fun derivePeerConfigText(
    xtcpName: String,
    stcpName: String,
    secretKey: String,
    stcpSecretKey: String,
    useEncryption: Boolean,
    useCompression: Boolean,
    localIp: String,
    localPort: String
): String {
    val peerIp = localIp.ifBlank { "127.0.0.1" }
    val peerPort = localPort.toIntOrNull()?.takeIf { it > 0 } ?: 22
    fun proxy(name: String, protocol: String, key: String) = FrpConfig(
        name = name,
        protocol = protocol,
        role = "server",
        secretKey = key.ifBlank { null },
        localIp = peerIp,
        localPort = peerPort,
        useEncryption = useEncryption,
        useCompression = useCompression
    )
    return buildString {
        appendLine("# ===== Peer frpc config (run on the target machine) =====")
        appendLine("# Adjust localIP / localPort to the actual service address on the peer")
        appendLine("# (e.g. localIP = \"192.168.3.18\", localPort = 22).")
        appendLine("# secretKey / encryption / compression must match this app.")
        appendLine()
        append(ConfigGenerator.generateProxyConfig(proxy(xtcpName.ifBlank { "xtcp_name" }, "xtcp", secretKey)))
        appendLine()
        append(ConfigGenerator.generateProxyConfig(proxy(stcpName.ifBlank { "stcp_name" }, "stcp", stcpSecretKey)))
    }
}

