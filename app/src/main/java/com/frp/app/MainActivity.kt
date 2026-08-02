package com.frp.app
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.window.PopupProperties

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import com.frp.app.data.ConfigImportExport
import com.frp.app.data.FrpConfig
import com.frp.app.data.FrpStatus
import com.frp.app.manager.ConnectionStatus
import com.frp.app.manager.ConnectionType
import com.frp.app.data.ServerConfig
import com.frp.app.ui.theme.FRPAndroidTheme
import com.frp.app.utils.NetworkUtils
import com.frp.app.viewmodel.MainViewModel
import com.frp.app.viewmodel.ConfigGroup
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initExcludeFromRecents(this)
        setContent {
            FRPAndroidTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    MainScreen()
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(viewModel: MainViewModel = viewModel()) {
    val configs by viewModel.allConfigs.collectAsState(initial = emptyList())
    val configGroups by viewModel.configGroups.collectAsState(initial = emptyList())
    val isRunning by viewModel.isRunning.collectAsState()
    val frpStatus by viewModel.frpStatus.collectAsState()
    val activeConfigId by viewModel.activeConfigId.collectAsState()
    val serverConfig by viewModel.serverConfig.collectAsState(initial = null)
    val connectionStatus by viewModel.connectionStatus.collectAsState()
    val context = LocalContext.current
    val configImportExport = remember { ConfigImportExport(context) }
    
    // Android 13+ 通知权限运行时请求（前台服务通知栏需要）
    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    
    // 导入配置的launcher
    val importLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        result.data?.data?.let { uri ->
            val json = configImportExport.readConfigFromUri(uri)
            if (json != null) {
                val importedConfigs = configImportExport.importConfigs(json)
                if (importedConfigs != null) {
                    importedConfigs.forEach { config ->
                        viewModel.addConfig(config)
                    }
                    Toast.makeText(context, "Imported ${importedConfigs.size} configurations", Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(context, "Failed to parse config file", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }
    
    // 导出配置的launcher - 使用SAF创建文档
    var pendingExportJson by remember { mutableStateOf<String?>(null) }
    val exportLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/json")
    ) { uri ->
        uri?.let {
            pendingExportJson?.let { json ->
                val success = configImportExport.writeConfigToUri(it, json)
                if (success) {
                    Toast.makeText(context, "Config exported successfully", Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(context, "Failed to export config", Toast.LENGTH_SHORT).show()
                }
            }
            pendingExportJson = null
        }
    }
    
    // 菜单状态
    var showMenu by remember { mutableStateOf(false) }
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("FRP Android") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.primary
                ),
                actions = {
                    // 日志按钮
                    IconButton(
                        onClick = {
                            context.startActivity(Intent(context, LogActivity::class.java))
                        }
                    ) {
                        Icon(Icons.Default.List, contentDescription = "Logs")
                    }
                    
                    // 流量统计按钮
                    IconButton(
                        onClick = {
                            context.startActivity(Intent(context, TrafficActivity::class.java))
                        }
                    ) {
                        Icon(Icons.Default.DataUsage, contentDescription = "Traffic")
                    }
                    
                    // 更多选项菜单
                    IconButton(onClick = { showMenu = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = "More")
                    }
                    
                    DropdownMenu(
                        expanded = showMenu,
                        onDismissRequest = { showMenu = false }
                    ) {
                        DropdownMenuItem(
                            text = { Text("Import Config") },
                            onClick = {
                                showMenu = false
                                importLauncher.launch(configImportExport.createImportIntent())
                            },
                            leadingIcon = { Icon(Icons.Default.FileUpload, contentDescription = null) }
                        )
                        DropdownMenuItem(
                            text = { Text("Export Config") },
                            onClick = {
                                showMenu = false
                                if (configs.isNotEmpty()) {
                                    val json = configImportExport.exportConfigs(configs)
                                    pendingExportJson = json
                                    exportLauncher.launch("frp_configs.json")
                                } else {
                                    Toast.makeText(context, "No configs to export", Toast.LENGTH_SHORT).show()
                                }
                            },
                            leadingIcon = { Icon(Icons.Default.FileDownload, contentDescription = null) }
                        )
                        DropdownMenuItem(
                            text = { Text("Settings") },
                            onClick = {
                                showMenu = false
                                context.startActivity(Intent(context, SettingsActivity::class.java))
                            },
                            leadingIcon = { Icon(Icons.Default.Settings, contentDescription = null) }
                        )
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = {
                    context.startActivity(Intent(context, ConfigEditActivity::class.java))
                }
            ) {
                Icon(Icons.Default.Add, contentDescription = "Add Config")
            }
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(16.dp)
        ) {
            // 服务器连接配置卡片（替换原状态卡片位置）
            ServerCard(
                serverConfig = serverConfig,
                isRunning = isRunning,
                frpStatus = frpStatus,
                connectionStatus = connectionStatus,
                activeConfig = configs.find { it.id == activeConfigId },
                onSave = { viewModel.saveServerConfig(it) },
                onStart = { viewModel.startAll() },
                onStop = { viewModel.stopFrp() }
            )
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // IP地址卡片
            IpAddressCard()
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // 内存占用卡片
            MemoryCard()
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // 配置列表
            Text(
                text = "Configurations (${configs.size})",
                style = MaterialTheme.typography.headlineSmall,
                modifier = Modifier.padding(bottom = 8.dp)
            )
            
            if (configs.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = "No configurations yet",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Tap + to add or import from menu",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                LazyColumn {
                    items(configGroups) { group ->
                        if (group.groupId > 0) {
                            // 分组配置：开关控制启用，随服务端连接一起启动
                            ConfigGroupItem(
                                group = group,
                                running = group.running,
                                enabled = group.enabled,
                                onEnabledChange = { enabled -> viewModel.setGroupEnabled(group.groupId, enabled) },
                                onEdit = {
                                    val intent = Intent(context, ConfigEditActivity::class.java).apply {
                                        putExtra("config_id", group.primaryConfig.id)
                                    }
                                    context.startActivity(intent)
                                },
                                onDelete = { viewModel.deleteGroup(group.groupId) }
                            )
                        } else {
                            // 单独配置
                            val config = group.primaryConfig
                            ConfigItem(
                                config = config,
                                running = config.id == activeConfigId,
                                enabled = config.enabled,
                                onEnabledChange = { enabled -> viewModel.setConfigEnabled(config.id, enabled) },
                                onEdit = {
                                    val intent = Intent(context, ConfigEditActivity::class.java).apply {
                                        putExtra("config_id", config.id)
                                    }
                                    context.startActivity(intent)
                                },
                                onDelete = { viewModel.deleteConfig(config) }
                            )
                        }
                    }
                }
            }
        }
    }
}
@Composable
fun MemoryCard() {
    // 应用自身内存占用：PSS（实际物理内存）+ Java 堆
    var pssMb by remember { mutableStateOf(0f) }
    var heapUsedMb by remember { mutableStateOf(0f) }
    var heapMaxMb by remember { mutableStateOf(0f) }
    
    // 每 2 秒刷新一次
    LaunchedEffect(Unit) {
        while (true) {
            val memInfo = Debug.MemoryInfo()
            Debug.getMemoryInfo(memInfo)
            pssMb = memInfo.getTotalPss() / 1024f
            val runtime = Runtime.getRuntime()
            heapUsedMb = (runtime.totalMemory() - runtime.freeMemory()) / (1024f * 1024f)
            heapMaxMb = runtime.maxMemory() / (1024f * 1024f)
            delay(2000)
        }
    }
    
    val heapPercent = if (heapMaxMb > 0) heapUsedMb / heapMaxMb else 0f
    
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(bottom = 8.dp)
            ) {
                Icon(
                    Icons.Default.Memory,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "App Memory",
                    style = MaterialTheme.typography.titleSmall
                )
            }
            
            Row(
                verticalAlignment = Alignment.Bottom,
                modifier = Modifier.padding(bottom = 4.dp)
            ) {
                Text(
                    text = "${pssMb.toInt()} MB",
                    style = MaterialTheme.typography.headlineMedium,
                    color = MaterialTheme.colorScheme.primary
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "PSS",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 4.dp)
                )
            }
            
            LinearProgressIndicator(
                progress = heapPercent,
                modifier = Modifier.fillMaxWidth()
            )
            
            Spacer(modifier = Modifier.height(6.dp))
            
            Text(
                text = "Heap: ${String.format("%.1f", heapUsedMb)} / ${String.format("%.1f", heapMaxMb)} MB (${(heapPercent * 100).toInt()}%)",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
fun IpAddressCard() {
    val context = LocalContext.current
    val ipAddresses = remember { NetworkUtils.getDeviceIpAddresses(context) }
    
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(bottom = 8.dp)
            ) {
                Icon(
                    Icons.Default.Language,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "Network Addresses",
                    style = MaterialTheme.typography.titleSmall
                )
            }
            
            if (ipAddresses.ipv4.isEmpty() && ipAddresses.ipv6.isEmpty()) {
                Text(
                    text = "No network connection",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            } else {
                // IPv4 地址
                if (ipAddresses.ipv4.isNotEmpty()) {
                    Text(
                        text = "IPv4",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(bottom = 2.dp)
                    )
                    ipAddresses.ipv4.take(2).forEach { ip ->
                        Text(
                            text = ip,
                            style = MaterialTheme.typography.bodySmall.copy(
                                fontFamily = FontFamily.Monospace
                            ),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(bottom = 2.dp)
                        )
                    }
                }
                
                // IPv6 地址
                if (ipAddresses.ipv6.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = "IPv6",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.secondary,
                        modifier = Modifier.padding(bottom = 2.dp)
                    )
                    ipAddresses.ipv6.take(2).forEach { ip ->
                        Text(
                            text = ip,
                            style = MaterialTheme.typography.bodySmall.copy(
                                fontFamily = FontFamily.Monospace,
                                fontSize = 10.sp
                            ),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(bottom = 2.dp)
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ServerCard(
    serverConfig: ServerConfig?,
    isRunning: Boolean,
    frpStatus: FrpStatus,
    connectionStatus: ConnectionStatus,
    activeConfig: FrpConfig?,
    onSave: (ServerConfig) -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    var showEditDialog by remember { mutableStateOf(false) }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClick = { expanded = !expanded },
                onLongClick = { if (!isRunning) showEditDialog = true }
            ),
        colors = CardDefaults.cardColors(
            containerColor = if (isRunning) {
                MaterialTheme.colorScheme.primaryContainer
            } else {
                MaterialTheme.colorScheme.surfaceVariant
            }
        )
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            val statusColor = when (frpStatus) {
                FrpStatus.RUNNING -> Color(0xFF4CAF50)
                FrpStatus.ERROR -> MaterialTheme.colorScheme.error
                FrpStatus.STOPPED -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
            }
            val statusText = when (frpStatus) {
                FrpStatus.RUNNING -> "Running"
                FrpStatus.ERROR -> "Error"
                FrpStatus.STOPPED -> "Stopped"
            }

            // 标题行
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(
                    imageVector = Icons.Default.Dns,
                    contentDescription = null,
                    tint = if (isRunning) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.width(8.dp))

                if (!expanded) {
                    // 折叠态：IP:Port
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "FRPS Server",
                            style = MaterialTheme.typography.titleMedium
                        )
                        val displayAddr = serverConfig?.serverAddr ?: ""
                        val displayPort = (serverConfig?.serverPort ?: 0).toString()
                        if (displayAddr.isNotBlank()) {
                            Text(
                                text = displayAddr + ":" + displayPort,
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                } else {
                    Text(
                        text = "FRPS Server",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.weight(1f)
                    )
                }

                // 状态圆点
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Canvas(modifier = Modifier.size(10.dp)) {
                        drawCircle(color = statusColor)
                    }
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = statusText,
                        style = MaterialTheme.typography.labelMedium,
                        color = statusColor
                    )
                }
                Spacer(modifier = Modifier.width(4.dp))
                Icon(
                    imageVector = if (expanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                    contentDescription = if (expanded) "Collapse" else "Expand",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // 展开后：只读展示
            if (expanded) {
                Spacer(modifier = Modifier.height(12.dp))

                val displayAddr = serverConfig?.serverAddr ?: "Not set"
                val displayPort = (serverConfig?.serverPort ?: 0).toString()
                Text(
                    text = displayAddr + ":" + displayPort,
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace)
                )

                val tokenDisplay = serverConfig?.token
                if (!tokenDisplay.isNullOrBlank()) {
                    Text(
                        text = "Token: *****",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                // 连接类型指示
                if (isRunning && connectionStatus.type != ConnectionType.UNKNOWN) {
                    Spacer(modifier = Modifier.height(8.dp))
                    val connColor = when (connectionStatus.type) {
                        ConnectionType.P2P -> Color(0xFF4CAF50)
                        ConnectionType.RELAY -> Color(0xFFFF9800)
                        ConnectionType.ERROR -> MaterialTheme.colorScheme.error
                        ConnectionType.UNKNOWN -> MaterialTheme.colorScheme.onSurfaceVariant
                    }
                    val connIcon = when (connectionStatus.type) {
                        ConnectionType.P2P -> Icons.Default.Link
                        ConnectionType.RELAY -> Icons.Default.SwapHoriz
                        ConnectionType.ERROR -> Icons.Default.ErrorOutline
                        ConnectionType.UNKNOWN -> Icons.Default.HelpOutline
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(connColor.copy(alpha = 0.1f), shape = MaterialTheme.shapes.small)
                            .padding(horizontal = 8.dp, vertical = 4.dp)
                    ) {
                        Icon(
                            imageVector = connIcon,
                            contentDescription = null,
                            tint = connColor,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text(
                            text = connectionStatus.detail,
                            style = MaterialTheme.typography.bodySmall,
                            color = connColor
                        )
                    }
                }

                if (isRunning) {
                    if (activeConfig != null) {
                        Text(
                            text = "Active: " + activeConfig.name,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Spacer(modifier = Modifier.height(12.dp))
                    Button(
                        onClick = onStop,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error
                        ),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.Stop, contentDescription = "Stop")
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("Stop FRP")
                    }
                } else {
                    Spacer(modifier = Modifier.height(12.dp))
                    Button(
                        onClick = onStart,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.PlayArrow, contentDescription = "Start")
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("Start FRP (all enabled)")
                    }
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = "Long press to edit server",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                    )
                }
            }
        }
    }

    // 长按编辑对话框
    if (showEditDialog) {
        ServerEditDialog(
            serverConfig = serverConfig,
            onDismiss = { showEditDialog = false },
            onSave = { newConfig ->
                showEditDialog = false
                onSave(newConfig)
            }
        )
    }
}

@Composable
fun ServerEditDialog(
    serverConfig: ServerConfig?,
    onDismiss: () -> Unit,
    onSave: (ServerConfig) -> Unit
) {
    var addr by remember { mutableStateOf(serverConfig?.serverAddr ?: "") }
    var port by remember { mutableStateOf((serverConfig?.serverPort ?: 7000).toString()) }
    var token by remember { mutableStateOf(serverConfig?.token ?: "") }
    var showToken by remember { mutableStateOf(false) }
    
    // Transport 连接配置
    var protocol by remember { mutableStateOf(serverConfig?.protocol ?: "tcp") }
    var tcpMux by remember { mutableStateOf(serverConfig?.tcpMux ?: true) }
    var heartbeatInterval by remember { mutableStateOf(serverConfig?.heartbeatInterval ?: 30) }
    var heartbeatTimeout by remember { mutableStateOf(serverConfig?.heartbeatTimeout ?: 90) }
    var tcpMuxKeepaliveInterval by remember { mutableStateOf(serverConfig?.tcpMuxKeepaliveInterval ?: 30) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit Server Connection") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState())
            ) {
                OutlinedTextField(
                    value = addr,
                    onValueChange = { addr = it },
                    label = { Text("Server Address *") },
                    placeholder = { Text("e.g., frp.example.com") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it },
                    label = { Text("Port") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = token,
                    onValueChange = { token = it },
                    label = { Text("Token") },
                    singleLine = true,
                    visualTransformation = if (showToken) VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        IconButton(onClick = { showToken = !showToken }) {
                            Icon(
                                if (showToken) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                                contentDescription = if (showToken) "Hide" else "Show"
                            )
                        }
                    },
                    modifier = Modifier.fillMaxWidth()
                )
                
                Spacer(modifier = Modifier.height(16.dp))
                Divider()
                Spacer(modifier = Modifier.height(8.dp))
                
                Text(
                    text = "Transport",
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.padding(bottom = 4.dp)
                )
                Text(
                    text = "Connection settings to frps (keep consistent with peer frpc)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 8.dp)
                )
                
                // Protocol 下拉
                TransportDropdown(
                    label = "Protocol",
                    options = listOf("tcp", "kcp", "quic", "ws", "wss"),
                    selected = protocol,
                    onSelected = { protocol = it }
                )
                Spacer(modifier = Modifier.height(8.dp))
                
                // tcpMux 开关
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("TCP Multiplexing (tcpMux)", style = MaterialTheme.typography.bodyMedium)
                    Switch(
                        checked = tcpMux,
                        onCheckedChange = { tcpMux = it }
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
                
                TransportDropdown(
                    label = "Heartbeat Interval (s)",
                    options = listOf(10, 20, 30, 60, 120),
                    selected = heartbeatInterval,
                    onSelected = { heartbeatInterval = it }
                )
                Spacer(modifier = Modifier.height(8.dp))
                TransportDropdown(
                    label = "Heartbeat Timeout (s)",
                    options = listOf(30, 60, 90, 120, 180, 300),
                    selected = heartbeatTimeout,
                    onSelected = { heartbeatTimeout = it }
                )
                Spacer(modifier = Modifier.height(8.dp))
                TransportDropdown(
                    label = "tcpMux Keepalive Interval (s)",
                    options = listOf(10, 20, 30, 60, 120, 300),
                    selected = tcpMuxKeepaliveInterval,
                    onSelected = { tcpMuxKeepaliveInterval = it }
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    val newPort = port.toIntOrNull() ?: (serverConfig?.serverPort ?: 7000)
                    onSave(ServerConfig(
                        serverAddr = addr.trim(),
                        serverPort = newPort,
                        token = token.trim(),
                        protocol = protocol,
                        tcpMux = tcpMux,
                        heartbeatInterval = heartbeatInterval,
                        heartbeatTimeout = heartbeatTimeout,
                        tcpMuxKeepaliveInterval = tcpMuxKeepaliveInterval
                    ))
                }
            ) {
                Text("Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun <T> TransportDropdown(
    label: String,
    options: List<T>,
    selected: T,
    onSelected: (T) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it }
    ) {
        OutlinedTextField(
            value = selected.toString(),
            onValueChange = {},
            readOnly = true,
            label = { Text(label) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor()
        )
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false }
        ) {
            options.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.toString()) },
                    onClick = {
                        onSelected(option)
                        expanded = false
                    }
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ConfigItem(
    config: FrpConfig,
    running: Boolean,
    enabled: Boolean,
    onEnabledChange: (Boolean) -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
) {
    var showDeleteDialog by remember { mutableStateOf(false) }
    var showContextMenu by remember { mutableStateOf(false) }
    
    val subtitle = when (config.protocol.lowercase()) {
        "stcp", "sudp", "xtcp" -> {
            if (config.isVisitor()) {
                "${config.protocol.uppercase()} Visitor -> ${config.bindAddr}:${config.bindPort}"
            } else {
                "${config.protocol.uppercase()} Server: ${config.localIp}:${config.localPort}"
            }
        }
        else -> {
            "${config.protocol.uppercase()} ${config.localIp}:${config.localPort} -> remote:${config.remotePort}"
        }
    }
    
    val detail = when (config.protocol.lowercase()) {
        "stcp", "sudp", "xtcp" -> {
            if (config.isVisitor()) {
                "Server: ${config.serverName ?: "N/A"} | Key: ${if (config.secretKey != null) "***" else "N/A"}"
            } else {
                "Remote: ${config.remotePort} | Key: ${if (config.secretKey != null) "***" else "N/A"}"
            }
        }
        else -> {
            "Protocol: ${config.protocol.uppercase()} | Remote: ${config.remotePort}"
        }
    }
    
    Box(modifier = Modifier.fillMaxWidth()) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 4.dp)
                .combinedClickable(
                    onClick = {},
                    onLongClick = { showContextMenu = true }
                ),
            colors = CardDefaults.cardColors(
                containerColor = if (running) {
                    MaterialTheme.colorScheme.secondaryContainer
                } else {
                    MaterialTheme.colorScheme.surface
                }
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
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = config.name,
                        style = MaterialTheme.typography.titleMedium
                    )
                    Text(
                        text = subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = detail,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(
                        checked = enabled,
                        onCheckedChange = onEnabledChange
                    )
                }
            }
            }
        }

        DropdownMenu(
            expanded = showContextMenu,
            onDismissRequest = { showContextMenu = false }
        ) {
            DropdownMenuItem(
                text = { Text("Edit") },
                leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
                onClick = {
                    showContextMenu = false
                    onEdit()
                }
            )
            DropdownMenuItem(
                text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
                leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                onClick = {
                    showContextMenu = false
                    showDeleteDialog = true
                }
            )
        }
    }

    if (showDeleteDialog) {
        AlertDialog(
            onDismissRequest = { showDeleteDialog = false },
            title = { Text("Delete Configuration") },
            text = { Text("Are you sure you want to delete '${config.name}'?") },
            confirmButton = {
                TextButton(
                    onClick = {
                        showDeleteDialog = false
                        onDelete()
                    }
                ) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ConfigGroupItem(
    group: ConfigGroup,
    running: Boolean,
    enabled: Boolean,
    onEnabledChange: (Boolean) -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    var showDeleteDialog by remember { mutableStateOf(false) }
    var showContextMenu by remember { mutableStateOf(false) }
    
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (running) {
                MaterialTheme.colorScheme.secondaryContainer
            } else {
                MaterialTheme.colorScheme.surface
            }
        )
    ) {
        Column {
            // 主配置行（可点击展开）
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .combinedClickable(
                        onClick = { expanded = !expanded },
                        onLongClick = { showContextMenu = true }
                    )
                    .padding(16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // 展开/折叠图标
                Icon(
                    if (expanded) Icons.Default.KeyboardArrowDown else Icons.Default.KeyboardArrowRight,
                    contentDescription = if (expanded) "Collapse" else "Expand",
                    modifier = Modifier.padding(end = 8.dp)
                )
                
                // 配置信息
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = group.groupName,
                        style = MaterialTheme.typography.titleMedium
                    )
                    Text(
                        text = "${group.primaryConfig.protocol.uppercase()} - ${group.primaryConfig.serverName}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = "${group.subConfigs.size + 1} configs",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                
                // 启用开关：随服务端连接一起启动
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(
                        checked = enabled,
                        onCheckedChange = onEnabledChange
                    )
                }
            }
            
            // 展开的子配置列表
            if (expanded) {
                Divider(modifier = Modifier.padding(horizontal = 16.dp))
                
                // 主配置详情
                SubConfigItem(
                    config = group.primaryConfig,
                    isPrimary = true
                )
                
                // 子配置
                group.subConfigs.forEach { config ->
                    SubConfigItem(
                        config = config,
                        isPrimary = false
                    )
                }
            }
        }
    }
    
    // 长按菜单
    Box(modifier = Modifier.fillMaxWidth()) {
        DropdownMenu(
            expanded = showContextMenu,
            onDismissRequest = { showContextMenu = false }
        ) {
            DropdownMenuItem(
                text = { Text("Edit") },
                leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
                onClick = {
                    showContextMenu = false
                    onEdit()
                }
            )
            DropdownMenuItem(
                text = { Text("Delete", color = MaterialTheme.colorScheme.error) },
                leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                onClick = {
                    showContextMenu = false
                    showDeleteDialog = true
                }
            )
        }
    }

    // 删除确认对话框
    if (showDeleteDialog) {
        AlertDialog(
            onDismissRequest = { showDeleteDialog = false },
            title = { Text("Delete Group") },
            text = { Text("Are you sure you want to delete '${group.groupName}' and all its configs?") },
            confirmButton = {
                TextButton(
                    onClick = {
                        showDeleteDialog = false
                        onDelete()
                    }
                ) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}

@Composable
fun SubConfigItem(
    config: FrpConfig,
    isPrimary: Boolean
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // 标记是否是主配置
        if (isPrimary) {
            Icon(
                Icons.Default.Star,
                contentDescription = "Primary",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .size(16.dp)
                    .padding(end = 4.dp)
            )
        } else {
            Spacer(modifier = Modifier.width(20.dp))
        }
        
        Column {
            Text(
                text = config.name,
                style = MaterialTheme.typography.bodyMedium
            )
            Text(
                text = "${config.protocol.uppercase()} - bindPort: ${config.bindPort}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
