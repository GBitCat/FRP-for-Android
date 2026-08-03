package com.frp.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
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
    
    // 设置状态
    val prefs = context.getSharedPreferences("frp_settings", Context.MODE_PRIVATE)
    var hideFromRecents by remember { mutableStateOf(prefs.getBoolean("hide_from_recents", false)) }
    var autoStart by remember { mutableStateOf(false) }
    var showNotifications by remember { mutableStateOf(true) }
    var keepAlive by remember { mutableStateOf(true) }
    var darkMode by remember { mutableStateOf(false) }
    var logRetention by remember { mutableStateOf("7") }
    
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
                    
                    // 深色模式
                    SettingsSwitch(
                        title = "Dark mode",
                        subtitle = "Use dark theme (requires restart)",
                        icon = Icons.Default.DarkMode,
                        checked = darkMode,
                        onCheckedChange = { darkMode = it }
                    )

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
