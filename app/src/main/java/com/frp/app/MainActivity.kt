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
import android.os.Process
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import com.frp.app.data.ConfigImportExport
import com.frp.app.data.FrpConfig
import com.frp.app.data.FrpStatus
import com.frp.app.manager.ConnectionStatus
import com.frp.app.manager.ConnectionType
import com.frp.app.manager.TrafficStats
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
    
    // Android 13+ 通知权限运行时请求（前台服务通知栏需要）
    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }
    
    // 底部导航当前页：0=仪表盘 1=配置 2=设置
    var selectedTab by remember { mutableStateOf(0) }
    
    // Server 编辑对话框（配置 Tab 入口）
    var showServerEditDialog by remember { mutableStateOf(false) }
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("FRP Android") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.primary
                )
            )
        },
        floatingActionButton = {
            if (selectedTab == 1) {
                FloatingActionButton(
                    onClick = {
                        context.startActivity(Intent(context, ConfigEditActivity::class.java))
                    }
                ) {
                    Icon(Icons.Default.Add, contentDescription = "Add Config")
                }
            }
        },
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    icon = { Icon(Icons.Default.Dashboard, contentDescription = null) },
                    label = { Text("Dashboard") }
                )
                NavigationBarItem(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    icon = { Icon(Icons.Default.List, contentDescription = null) },
                    label = { Text("Configs") }
                )
                NavigationBarItem(
                    selected = selectedTab == 2,
                    onClick = { selectedTab = 2 },
                    icon = { Icon(Icons.Default.Settings, contentDescription = null) },
                    label = { Text("Settings") }
                )
            }
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            // ========== 仪表盘 Tab ==========
            if (selectedTab == 0) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(16.dp)
                ) {
            // 服务器连接配置卡片
            ServerCard(
                serverConfig = serverConfig,
                isRunning = isRunning,
                frpStatus = frpStatus,
                connectionStatus = connectionStatus,
                activeConfig = configs.find { it.id == activeConfigId },
                onStart = { viewModel.startAll() },
                onStop = { viewModel.stopFrp() }
            )
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // IP 与内存卡片并排（各占一半，强制等高）
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Box(modifier = Modifier.weight(1f)) {
                    IpAddressCard()
                }
                Box(modifier = Modifier.weight(1f)) {
                    MemoryCard()
                }
            }
            
            Spacer(modifier = Modifier.height(12.dp))
            
            // 流量统计卡片（紧凑版，点击进入详情）
            TrafficCard()
                }
            }
            
            // ========== 配置 Tab ==========
            if (selectedTab == 1) {
                Column(modifier = Modifier.padding(16.dp)) {
            // Server 配置栏（编辑入口）
            Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainerLow
                )
            ) {
                Row(
                    modifier = Modifier.padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        Icons.Default.Dns,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = serverConfig?.name?.ifBlank { "FRPS Server" } ?: "FRPS Server",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "${serverConfig?.serverAddr ?: "Not set"}:${serverConfig?.serverPort ?: 0}",
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    IconButton(onClick = { showServerEditDialog = true }) {
                        Icon(Icons.Default.Edit, contentDescription = "Edit server")
                    }
                }
            }
            
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
            
            // ========== 设置 Tab ==========
            if (selectedTab == 2) {
                SettingsContent()
            }
        }
    }
    
    // Server 编辑对话框（配置 Tab 的 FRPS Server 栏）
    if (showServerEditDialog) {
        ServerEditDialog(
            serverConfig = serverConfig,
            onDismiss = { showServerEditDialog = false },
            onSave = { newConfig ->
                showServerEditDialog = false
                viewModel.saveServerConfig(newConfig)
            }
        )
    }
}
@Composable
fun MemoryCard() {
    // 应用自身内存占用：PSS（实际物理内存）+ Java 堆
    var pssMb by remember { mutableStateOf(0f) }
    var heapUsedMb by remember { mutableStateOf(0f) }
    var heapMaxMb by remember { mutableStateOf(0f) }
    
    // 每 2 秒刷新一次（Debug.getMemoryInfo 有开销，放 IO 线程避免阻塞主线程）
    LaunchedEffect(Unit) {
        while (true) {
            val memInfo = withContext(Dispatchers.IO) {
                Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }
            }
            pssMb = memInfo.getTotalPss() / 1024f
            val runtime = Runtime.getRuntime()
            heapUsedMb = (runtime.totalMemory() - runtime.freeMemory()) / (1024f * 1024f)
            heapMaxMb = runtime.maxMemory() / (1024f * 1024f)
            delay(2000)
        }
    }
    
    val heapPercent = if (heapMaxMb > 0) heapUsedMb / heapMaxMb else 0f
    
    Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
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
                    style = MaterialTheme.typography.headlineSmall,
                    color = MaterialTheme.colorScheme.primary
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = "PSS",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 2.dp)
                )
            }
            
            LinearProgressIndicator(
                progress = heapPercent,
                modifier = Modifier.fillMaxWidth()
            )
            
            Spacer(modifier = Modifier.height(4.dp))
            
            Text(
                text = "Heap ${(heapPercent * 100).toInt()}%",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrafficCard() {
    val context = LocalContext.current
    val trafficStats = remember { TrafficStats.getInstance() }
    val trafficState by trafficStats.trafficState.collectAsState()
    
    // 每秒采样 app UID 流量与 TCP 连接数（与 TrafficActivity 共用单例）
    // 采样含文件 IO（/proc/net/tcp），必须放到 IO 线程避免阻塞主线程导致触摸卡顿
    LaunchedEffect(Unit) {
        val uid = Process.myUid()
        while (true) {
            withContext(Dispatchers.IO) {
                trafficStats.sampleUidTraffic(uid)
                trafficStats.sampleTcpConnections(uid)
            }
            delay(1000)
        }
    }
    
    Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        onClick = { context.startActivity(Intent(context, TrafficActivity::class.java)) },
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
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
                    Icons.Default.DataUsage,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "Traffic",
                    style = MaterialTheme.typography.titleSmall
                )
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = "${trafficState.activeConnections} conn",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Icon(
                    Icons.Default.ChevronRight,
                    contentDescription = "Details",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(18.dp)
                )
            }
            
            Row(
                modifier = Modifier.fillMaxWidth()
            ) {
                // 三等分固定列：标识位置固定，数值以标识为中心居中
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = trafficStats.formatSpeed(trafficState.uploadSpeed),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1
                    )
                    Text(
                        text = "Upload",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = trafficStats.formatSpeed(trafficState.downloadSpeed),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.secondary,
                        maxLines = 1
                    )
                    Text(
                        text = "Download",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = trafficStats.formatBytes(trafficState.totalSent + trafficState.totalReceived),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                        maxLines = 1
                    )
                    Text(
                        text = "Total",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
fun IpAddressCard() {
    val context = LocalContext.current
    val ipAddresses = remember { NetworkUtils.getDeviceIpAddresses(context) }
    
    Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerLow
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
                    ipAddresses.ipv4.take(1).forEach { ip ->
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
                    ipAddresses.ipv6.take(1).forEach { ip ->
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

@Composable
fun ServerCard(
    serverConfig: ServerConfig?,
    isRunning: Boolean,
    frpStatus: FrpStatus,
    connectionStatus: ConnectionStatus,
    activeConfig: FrpConfig?,
    onStart: () -> Unit,
    onStop: () -> Unit
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
    val displayName = serverConfig?.name?.ifBlank { "FRPS Server" } ?: "FRPS Server"
    
    Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
        modifier = Modifier.fillMaxWidth(),
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
            // 标题行：图标 + 信息 + 状态 + 运行开关
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
                
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = displayName,
                        style = MaterialTheme.typography.titleMedium
                    )
                }
                
                // 状态圆点 + 文本
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
                Spacer(modifier = Modifier.width(8.dp))
                
                // 运行开关（启动/停止）
                Switch(
                    checked = isRunning,
                    onCheckedChange = { enabled ->
                        if (enabled) onStart() else onStop()
                    }
                )
            }
            
            // 连接方式：未启动时显示无连接
            Spacer(modifier = Modifier.height(8.dp))
            val connColor = when {
                !isRunning -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                connectionStatus.type == ConnectionType.P2P -> Color(0xFF4CAF50)
                connectionStatus.type == ConnectionType.RELAY -> Color(0xFFFF9800)
                connectionStatus.type == ConnectionType.ERROR -> MaterialTheme.colorScheme.error
                else -> MaterialTheme.colorScheme.onSurfaceVariant
            }
            val connIcon = when {
                !isRunning -> Icons.Default.HelpOutline
                connectionStatus.type == ConnectionType.P2P -> Icons.Default.Link
                connectionStatus.type == ConnectionType.RELAY -> Icons.Default.SwapHoriz
                connectionStatus.type == ConnectionType.ERROR -> Icons.Default.ErrorOutline
                else -> Icons.Default.HelpOutline
            }
            val connText = when {
                !isRunning -> "No connection"
                connectionStatus.type == ConnectionType.UNKNOWN -> "Connecting..."
                else -> connectionStatus.detail
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
                    text = connText,
                    style = MaterialTheme.typography.bodySmall,
                    color = connColor
                )
            }
            
            // Active 状态：未启动时显示未启动
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = if (isRunning && activeConfig != null) {
                    "Active: " + activeConfig.name
                } else {
                    "Active: Not running"
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
fun ServerEditDialog(
    serverConfig: ServerConfig?,
    onDismiss: () -> Unit,
    onSave: (ServerConfig) -> Unit
) {
    var name by remember { mutableStateOf((serverConfig?.name ?: "").ifBlank { "FRPS Server" }) }
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
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Name") },
                    placeholder = { Text("e.g., Home Server") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
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
                        name = name.trim().ifEmpty { "FRPS Server" },
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
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
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
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
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
