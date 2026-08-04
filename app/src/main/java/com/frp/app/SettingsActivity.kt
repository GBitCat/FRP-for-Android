package com.frp.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.widget.Toast
import com.frp.app.data.ConfigImportExport
import com.frp.app.data.ThemeSettingsHolder
import com.frp.app.manager.TrafficStats
import com.frp.app.viewmodel.MainViewModel
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.frp.app.ui.theme.FRPAndroidTheme

// 应用「最近任务隐藏」到当前 task
fun applyExcludeFromRecents(context: Context, exclude: Boolean) {
    try {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        for (task in am.appTasks) {
            task.setExcludeFromRecents(exclude)
        }
    } catch (e: Exception) {
        e.printStackTrace()
    }
}

// 在 Activity 启动时调用，确保设置生效
fun initExcludeFromRecents(activity: ComponentActivity) {
    val prefs = activity.getSharedPreferences("frp_settings", Context.MODE_PRIVATE)
    if (prefs.getBoolean("hide_from_recents", false)) {
        applyExcludeFromRecents(activity, true)
    }
}

class SettingsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            FRPAndroidTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    SettingsScreen(
                        onBack = { finish() }
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsContent() {
    val context = LocalContext.current
    val viewModel: MainViewModel = viewModel()
    val configs by viewModel.allConfigs.collectAsState(initial = emptyList())
    val configImportExport = remember { ConfigImportExport(context) }
    
    // 导入配置 launcher（SAF 文件选择）
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
    
    // 导出配置 launcher（SAF 创建文档）
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
    
    // 设置状态
    val prefs = context.getSharedPreferences("frp_settings", Context.MODE_PRIVATE)
    var hideFromRecents by remember { mutableStateOf(prefs.getBoolean("hide_from_recents", false)) }
    var autoStart by remember { mutableStateOf(false) }
    var showNotifications by remember { mutableStateOf(true) }
    var keepAlive by remember { mutableStateOf(true) }
    val themeMode by ThemeSettingsHolder.themeMode.collectAsState()
    val themeColor by ThemeSettingsHolder.primaryColor.collectAsState()
    var logRetention by remember { mutableStateOf("7") }
    var trafficStatsEnabled by remember { mutableStateOf(prefs.getBoolean("traffic_stats_enabled", false)) }
    
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
    ) {
            // 通用设置
            Text(
                text = "General",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(16.dp)
            )
            
            Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
            ) {
                Column {
                    // 开机自启
                    SettingsSwitch(
                        title = "Auto-start on boot",
                        subtitle = "Start FRP automatically when device boots",
                        icon = Icons.Default.PowerSettingsNew,
                        checked = autoStart,
                        onCheckedChange = { autoStart = it }
                    )
                    
                    Divider(modifier = Modifier.padding(horizontal = 16.dp))
                    
                    // 显示通知
                    SettingsSwitch(
                        title = "Show notifications",
                        subtitle = "Show persistent notification when FRP is running",
                        icon = Icons.Default.Notifications,
                        checked = showNotifications,
                        onCheckedChange = { showNotifications = it }
                    )
                    
                    Divider(modifier = Modifier.padding(horizontal = 16.dp))
                    
                    // 保持连接
                    SettingsSwitch(
                        title = "Keep alive",
                        subtitle = "Try to reconnect if connection is lost",
                        icon = Icons.Default.Sync,
                        checked = keepAlive,
                        onCheckedChange = { keepAlive = it }
                    )
                    
                    Divider(modifier = Modifier.padding(horizontal = 16.dp))
                    
                    // 主题模式
                    Text(
                        text = "Theme mode",
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        listOf("System" to "system", "Light" to "light", "Dark" to "dark").forEach { (label, value) ->
                            FilterChip(
                                selected = themeMode == value,
                                onClick = { ThemeSettingsHolder.setThemeMode(context, value) },
                                label = { Text(label) },
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                    
                    // 主题色（参考 FlClash 预设主色；Auto = 跟随系统动态色）
                    Text(
                        text = "Theme color",
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        // 系统动态（Auto）
                        Box(
                            modifier = Modifier
                                .size(32.dp)
                                .clip(androidx.compose.foundation.shape.CircleShape)
                                .background(
                                    if (themeColor == null) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.surfaceVariant
                                )
                                .border(
                                    width = 2.dp,
                                    color = if (themeColor == null) MaterialTheme.colorScheme.primary else Color.Transparent,
                                    shape = androidx.compose.foundation.shape.CircleShape
                                )
                                .clickable { ThemeSettingsHolder.setPrimaryColor(context, null) },
                            contentAlignment = Alignment.Center
                        ) {
                            Text("A", style = MaterialTheme.typography.labelSmall)
                        }
                        listOf(
                            0xFF795548.toInt(), 0xFF03A9F4.toInt(), 0xFFFFFF00.toInt(),
                            0xFFBBC9CC.toInt(), 0xFFABD397.toInt(), 0xFFD8C0C3.toInt(), 0xFF665390.toInt()
                        ).forEach { color ->
                            Box(
                                modifier = Modifier
                                    .size(32.dp)
                                    .clip(androidx.compose.foundation.shape.CircleShape)
                                    .background(Color(color))
                                    .border(
                                        width = 2.dp,
                                        color = if (themeColor == color) MaterialTheme.colorScheme.primary else Color.Transparent,
                                        shape = androidx.compose.foundation.shape.CircleShape
                                    )
                                    .clickable { ThemeSettingsHolder.setPrimaryColor(context, color) }
                            )
                        }
                    }
                    Spacer(modifier = Modifier.height(8.dp))

                    Divider(modifier = Modifier.padding(horizontal = 16.dp))

                    // 最近任务中隐藏
                    SettingsSwitch(
                        title = "Hide from recent apps",
                        subtitle = "App will not appear in the recent apps list",
                        icon = Icons.Default.VisibilityOff,
                        checked = hideFromRecents,
                        onCheckedChange = { enabled ->
                            hideFromRecents = enabled
                            prefs.edit().putBoolean("hide_from_recents", enabled).apply()
                            // 对所有 activity 生效
                            applyExcludeFromRecents(context, enabled)
                        }
                    )
                    
                    Divider(modifier = Modifier.padding(horizontal = 16.dp))
                    
                    // 流量统计
                    SettingsSwitch(
                        title = "Traffic statistics",
                        subtitle = "Monitor real-time traffic speed (may cost CPU)",
                        icon = Icons.Default.DataUsage,
                        checked = trafficStatsEnabled,
                        onCheckedChange = { enabled ->
                            trafficStatsEnabled = enabled
                            prefs.edit().putBoolean("traffic_stats_enabled", enabled).apply()
                            TrafficStats.getInstance().setEnabled(enabled)
                        }
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // 日志设置
            Text(
                text = "Logs",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(16.dp)
            )
            
            Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
            ) {
                Column {
                    // 日志保留天数
                    SettingsDropdown(
                        title = "Log retention",
                        subtitle = "Keep logs for $logRetention days",
                        icon = Icons.Default.History,
                        options = listOf("1", "3", "7", "14", "30"),
                        selectedOption = logRetention,
                        onOptionSelected = { logRetention = it }
                    )
                    
                    Divider(modifier = Modifier.padding(horizontal = 16.dp))
                    
                    // 查看日志
                    SettingsClickableItem(
                        title = "View logs",
                        subtitle = "Open frpc log viewer",
                        icon = Icons.Default.List,
                        onClick = {
                            context.startActivity(Intent(context, LogActivity::class.java))
                        }
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // 数据管理
            Text(
                text = "Data",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(16.dp)
            )
            
            Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
            ) {
                Column {
                    // 导入配置
                    SettingsClickableItem(
                        title = "Import Config",
                        subtitle = "Import configurations from JSON file",
                        icon = Icons.Default.FileUpload,
                        onClick = {
                            importLauncher.launch(configImportExport.createImportIntent())
                        }
                    )
                    
                    Divider(modifier = Modifier.padding(horizontal = 16.dp))
                    
                    // 导出配置
                    SettingsClickableItem(
                        title = "Export Config",
                        subtitle = "Export all configurations to JSON file",
                        icon = Icons.Default.FileDownload,
                        onClick = {
                            if (configs.isNotEmpty()) {
                                pendingExportJson = configImportExport.exportConfigs(configs)
                                exportLauncher.launch("frp_configs.json")
                            } else {
                                Toast.makeText(context, "No configs to export", Toast.LENGTH_SHORT).show()
                            }
                        }
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(16.dp))
            
            // 关于
            Text(
                text = "About",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(16.dp)
            )
            
            var showLicensesDialog by remember { mutableStateOf(false) }
            
            Card(
            elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
            shape = RoundedCornerShape(16.dp),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f)),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
            ) {
                Column {
                    // 版本
                    SettingsItem(
                        title = "Version",
                        subtitle = "1.0.0",
                        icon = Icons.Default.Info
                    )
                    
                    Divider(modifier = Modifier.padding(horizontal = 16.dp))
                    
                    // 开源许可
                    SettingsClickableItem(
                        title = "Open source licenses",
                        subtitle = "View third-party licenses",
                        icon = Icons.Default.Description,
                        onClick = { showLicensesDialog = true }
                    )
                    
                    Divider(modifier = Modifier.padding(horizontal = 16.dp))
                    
                    // GitHub（frp 官方项目）
                    SettingsClickableItem(
                        title = "GitHub",
                        subtitle = "frp project on GitHub",
                        icon = Icons.Default.Code,
                        onClick = {
                            val intent = Intent(
                                Intent.ACTION_VIEW,
                                android.net.Uri.parse("https://github.com/fatedier/frp")
                            )
                            context.startActivity(intent)
                        }
                    )
                }
            }
            
            Spacer(modifier = Modifier.height(32.dp))
            
            // 开源许可对话框
            if (showLicensesDialog) {
                AlertDialog(
                    onDismissRequest = { showLicensesDialog = false },
                    title = { Text("Open Source Licenses") },
                    text = {
                        Column(
                            modifier = Modifier.verticalScroll(rememberScrollState())
                        ) {
                            Text(
                                text = "Kotlin - Apache 2.0\nAndroidX / Jetpack - Apache 2.0\nJetpack Compose - Apache 2.0\nRoom - Apache 2.0\nGson - Apache 2.0\nfrp (fatedier) - Apache 2.0\nMaterial Icons - Apache 2.0",
                                style = MaterialTheme.typography.bodySmall
                            )
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = { showLicensesDialog = false }) {
                            Text("OK")
                        }
                    }
                )
            }
            
            // 底部文字
            Text(
                text = "FRP Android - Fast Reverse Proxy Client",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center
            )
        }
}

/**
 * 设置页（独立 Activity 用，主界面设置 Tab 直接使用 [SettingsContent]）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            SettingsContent()
        }
    }
}

@Composable
fun SettingsSwitch(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(24.dp)
        )
        Spacer(modifier = Modifier.width(16.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange
        )
    }
}

@Composable
fun SettingsDropdown(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    options: List<String>,
    selectedOption: String,
    onOptionSelected: (String) -> Unit
) {
    var expanded by remember { mutableStateOf(false) }
    
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(24.dp)
        )
        Spacer(modifier = Modifier.width(16.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        Box {
            TextButton(onClick = { expanded = true }) {
                Text(selectedOption)
                Icon(Icons.Default.ArrowDropDown, contentDescription = null)
            }
            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false }
            ) {
                options.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(option) },
                        onClick = {
                            onOptionSelected(option)
                            expanded = false
                        }
                    )
                }
            }
        }
    }
}

@Composable
fun SettingsItem(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(24.dp)
        )
        Spacer(modifier = Modifier.width(16.dp))
        Column {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
fun SettingsClickableItem(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit
) {
    Surface(
        onClick = onClick
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(24.dp)
            )
            Spacer(modifier = Modifier.width(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.bodyLarge
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Icon(
                imageVector = Icons.Default.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
