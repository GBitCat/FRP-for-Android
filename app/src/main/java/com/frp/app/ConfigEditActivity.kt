package com.frp.app

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
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
                name = config.name
                localIp = config.localIp
                localPort = config.localPort.toString()
                remotePort = config.remotePort.toString()
                protocol = config.protocol
                role = config.role
                secretKey = config.secretKey ?: ""
                serverName = config.serverName ?: ""
                bindPort = config.bindPort.toString()
                bindAddr = config.bindAddr
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
                            val config = FrpConfig(
                                id = configId ?: 0,
                                name = name,
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
                                fallbackTo = if (useFallback) {
                                    if (useCustomStcp) stcpName.ifBlank { autoStcpName } else autoStcpName
                                } else "",
                                
                                
                                fallbackTimeoutMs = fallbackTimeoutMs.toIntOrNull() ?: 3000,
                                useCustomStcp = useCustomStcp,
                                stcpName = stcpName.ifBlank { autoStcpName },
                                stcpSecretKey = stcpSecretKey.ifBlank { secretKey },
                                stcpServerName = stcpServerName.ifBlank { serverName.replace("xtcp", "stcp") },
                                stcpBindPort = stcpBindPort.toIntOrNull() ?: -1,
                                stcpBindAddr = stcpBindAddr,
                                groupId = originalConfig?.groupId ?: 0L,
                                groupName = originalConfig?.groupName ?: "",
                                isGroupPrimary = originalConfig?.isGroupPrimary ?: false,
                                linkedConfigId = originalConfig?.linkedConfigId ?: 0L,
                                enabled = originalConfig?.enabled ?: true,
                                isActive = originalConfig?.isActive ?: false,
                                createdAt = originalConfig?.createdAt ?: System.currentTimeMillis()
                            )
                            
                            val error = configGenerator.validateConfig(config)
                            if (error != null) {
                                Toast.makeText(context, error, Toast.LENGTH_SHORT).show()
                                return@TextButton
                            }
                            
                            if (isEditing) {
                                viewModel.updateConfig(config)
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
            
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Configuration Name *") },
                placeholder = { Text("e.g., xtcp-visitor") },
                modifier = Modifier.fillMaxWidth()
            )
            
            Spacer(modifier = Modifier.height(16.dp))
            
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
                        Text(
                            text = "${protocol.uppercase()} Settings",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.padding(bottom = 12.dp)
                        )
                        
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
                                    onValueChange = { serverName = it },
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
                                        onCheckedChange = { useFallback = it }
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
                                                "secretKey: ${secretKey.ifBlank { "(from XTCP)" }}\n" +
                                                "serverName: ${serverName.ifBlank { "(from XTCP)" }}\n" +
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
                                useCompression = useCompression
                            )
                        } else {
                            val xtcpPreview = FrpConfig(
                                name = name.ifBlank { "preview" },
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
                            configGenerator.createLinkedStcpConfig(xtcpPreview)
                        }
                    } else null
                    
                    val previewXtcpConfig = FrpConfig(
                        name = name.ifBlank { "preview" },
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
                    
                    val previewText = configGenerator.generateFullConfig(
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
                }
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
                                groupId = groupId,
                                groupName = finalGroupName,
                                isGroupPrimary = false
                            )
                        } else {
                            configGenerator.createLinkedStcpConfig(pendingSaveConfig!!).copy(
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
