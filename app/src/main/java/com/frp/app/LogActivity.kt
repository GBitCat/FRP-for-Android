package com.frp.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.frp.app.manager.LogEntry
import com.frp.app.manager.LogLevel
import com.frp.app.service.FrpService
import com.frp.app.ui.theme.FRPAndroidTheme

class LogActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            FRPAndroidTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    LogScreen(
                        onBack = { finish() }
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LogScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val logManager = remember { FrpService.logManager }
    val logs by logManager.logs.collectAsState()
    val listState = rememberLazyListState()
    
    // 过滤状态
    var selectedLevel by remember { mutableStateOf<LogLevel?>(null) }
    var autoScroll by remember { mutableStateOf(true) }
    
    // 自动滚动到底部
    LaunchedEffect(logs.size) {
        if (autoScroll && logs.isNotEmpty()) {
            listState.animateScrollToItem(logs.size - 1)
        }
    }
    
    // 过滤后的日志
    val filteredLogs = if (selectedLevel != null) {
        logs.filter { it.level == selectedLevel }
    } else {
        logs
    }
    
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("FRP Logs") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    // 自动滚动开关
                    IconButton(
                        onClick = { autoScroll = !autoScroll }
                    ) {
                        Icon(
                            if (autoScroll) Icons.Default.VerticalAlignBottom else Icons.Default.VerticalAlignTop,
                            contentDescription = if (autoScroll) "Auto-scroll ON" else "Auto-scroll OFF",
                            tint = if (autoScroll) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    
                    // 复制日志
                    IconButton(
                        onClick = {
                            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            val clip = ClipData.newPlainText("FRP Logs", logManager.getFormattedLogs())
                            clipboard.setPrimaryClip(clip)
                            Toast.makeText(context, "Logs copied to clipboard", Toast.LENGTH_SHORT).show()
                        }
                    ) {
                        Icon(Icons.Default.ContentCopy, contentDescription = "Copy Logs")
                    }
                    
                    // 清除日志
                    IconButton(
                        onClick = { logManager.clearLogs() }
                    ) {
                        Icon(Icons.Default.DeleteSweep, contentDescription = "Clear Logs")
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
            // 日志级别过滤器
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                FilterChip(
                    selected = selectedLevel == null,
                    onClick = { selectedLevel = null },
                    label = { Text("All") }
                )
                FilterChip(
                    selected = selectedLevel == LogLevel.DEBUG,
                    onClick = { selectedLevel = LogLevel.DEBUG },
                    label = { Text("Debug") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Color.Gray.copy(alpha = 0.3f)
                    )
                )
                FilterChip(
                    selected = selectedLevel == LogLevel.INFO,
                    onClick = { selectedLevel = LogLevel.INFO },
                    label = { Text("Info") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Color.Blue.copy(alpha = 0.3f)
                    )
                )
                FilterChip(
                    selected = selectedLevel == LogLevel.WARN,
                    onClick = { selectedLevel = LogLevel.WARN },
                    label = { Text("Warn") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Color.Yellow.copy(alpha = 0.3f)
                    )
                )
                FilterChip(
                    selected = selectedLevel == LogLevel.ERROR,
                    onClick = { selectedLevel = LogLevel.ERROR },
                    label = { Text("Error") },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Color.Red.copy(alpha = 0.3f)
                    )
                )
            }
            
            // 日志统计
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "Total: ${logs.size} | Filtered: ${filteredLogs.size}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = if (autoScroll) "Auto-scroll: ON" else "Auto-scroll: OFF",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (autoScroll) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            
            Divider(modifier = Modifier.padding(horizontal = 8.dp))
            
            // 日志列表
            if (filteredLogs.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(16.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            Icons.Default.Article,
                            contentDescription = null,
                            modifier = Modifier.size(48.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "No logs yet",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Text(
                            text = "Start FRP to see logs",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize()
                ) {
                    items(filteredLogs) { log ->
                        LogItem(log)
                    }
                }
            }
        }
    }
}

@Composable
fun LogItem(log: LogEntry) {
    val backgroundColor = when (log.level) {
        LogLevel.ERROR -> Color.Red.copy(alpha = 0.1f)
        LogLevel.WARN -> Color.Yellow.copy(alpha = 0.1f)
        LogLevel.DEBUG -> Color.Gray.copy(alpha = 0.1f)
        LogLevel.INFO -> Color.Transparent
    }
    
    val textColor = when (log.level) {
        LogLevel.ERROR -> Color.Red
        LogLevel.WARN -> Color(0xFF8B6914)
        LogLevel.DEBUG -> Color.Gray
        LogLevel.INFO -> MaterialTheme.colorScheme.onSurface
    }
    
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(backgroundColor)
            .padding(horizontal = 8.dp, vertical = 2.dp),
        verticalAlignment = Alignment.Top
    ) {
        // 时间戳
        Text(
            text = log.getFormattedTimestamp(),
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp
            ),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.width(60.dp)
        )
        
        Spacer(modifier = Modifier.width(4.dp))
        
        // 级别标签
        Text(
            text = log.level.name.first().toString(),
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp
            ),
            color = textColor,
            modifier = Modifier.width(12.dp)
        )
        
        Spacer(modifier = Modifier.width(4.dp))
        
        // 标签
        Text(
            text = "[${log.tag}]",
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp
            ),
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.width(80.dp)
        )
        
        Spacer(modifier = Modifier.width(4.dp))
        
        // 消息
        Text(
            text = log.message,
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp
            ),
            color = textColor,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
    }
}
