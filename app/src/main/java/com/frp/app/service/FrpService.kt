package com.frp.app.service

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.frp.app.FrpApplication
import com.frp.app.MainActivity
import com.frp.app.R
import com.frp.app.data.AppDatabase
import com.frp.app.data.ConfigGenerator
import com.frp.app.data.FrpStatus
import com.frp.app.data.FrpStatusHolder
import com.frp.app.manager.ConnectionStatusParser
import com.frp.app.manager.ConnectionType
import com.frp.app.manager.FrpManager
import com.frp.app.manager.LogLevel
import com.frp.app.manager.LogManager
import com.frp.app.manager.TrafficStats
import kotlinx.coroutines.*

class FrpService : Service() {
    
    private lateinit var frpManager: FrpManager
    private lateinit var configGenerator: ConfigGenerator
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    
    companion object {
        private const val TAG = "FrpService"
        private const val NOTIFICATION_ID = 1
        
        const val ACTION_START = "com.frp.app.START_FRP"
        const val ACTION_STOP = "com.frp.app.STOP_FRP"
        
        val logManager = LogManager()
        
        fun startService(context: Context) {
            val intent = Intent(context, FrpService::class.java).apply {
                action = ACTION_START
            }
            context.startForegroundService(intent)
        }
        
        fun stopService(context: Context) {
            val intent = Intent(context, FrpService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }
    
    override fun onCreate() {
        super.onCreate()
        frpManager = FrpManager(this)
        configGenerator = ConfigGenerator(this)
        logManager.addLog(LogLevel.INFO, TAG, "Service created")
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 立即启动前台服务，避免ForegroundServiceDidNotStartInTimeException
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, createNotification("Starting FRP..."), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, createNotification("Starting FRP..."))
        }
        
        when (intent?.action) {
            ACTION_START -> {
                startFrp()
            }
            ACTION_STOP -> {
                stopFrp()
            }
            else -> {
                stopSelf()
            }
        }
        return START_STICKY
    }
    
    override fun onBind(intent: Intent?): IBinder? {
        return null
    }
    
    private fun startFrp() {
        serviceScope.launch {
            try {
                logManager.addLog(LogLevel.INFO, TAG, "Starting FRP with all enabled configs")
                
                val database = AppDatabase.getDatabase(this@FrpService)
                val enabledConfigs = database.frpConfigDao().getEnabledConfigsSync()
                
                if (enabledConfigs.isEmpty()) {
                    logManager.addLog(LogLevel.ERROR, TAG, "No enabled config found. Please enable at least one config.")
                    FrpStatusHolder.set(this@FrpService, FrpStatus.ERROR)
                    updateNotification("Error: No enabled config")
                    delay(2000)
                    stopSelf()
                    return@launch
                }
                
                logManager.addLog(LogLevel.INFO, TAG, "Enabled configs: ${enabledConfigs.map { it.name }}")
                
                // 加载全局服务器连接配置
                val server = database.serverConfigDao().getServerConfigSync()
                if (server == null || !server.isValid()) {
                    logManager.addLog(LogLevel.ERROR, TAG, "Server not configured. Please set server address on main screen.")
                    FrpStatusHolder.set(this@FrpService, FrpStatus.ERROR)
                    updateNotification("Error: Server not configured")
                    delay(2000)
                    stopSelf()
                    return@launch
                }
                logManager.addLog(LogLevel.INFO, TAG, "Server: ${server.serverAddr}:${server.serverPort}")
                
                val configFile = configGenerator.saveAllConfigFile(server, enabledConfigs)
                logManager.addLog(LogLevel.INFO, TAG, "Config file saved: ${configFile.absolutePath}")
                
                // 新会话：重置流量统计（总量/速度/连接数，基准随 UID 采样重新建立）
                TrafficStats.getInstance().reset()
                
                frpManager.stopFrpc()  // 先停止现有进程
                logManager.addLog(LogLevel.INFO, TAG, "Installing frpc binary...")
                val installed = frpManager.installFrpc()
                if (!installed) {
                    logManager.addLog(LogLevel.ERROR, TAG, "Failed to install frpc")
                    FrpStatusHolder.set(this@FrpService, FrpStatus.ERROR)
                    updateNotification("Error: frpc not found")
                    delay(2000)
                    stopSelf()
                    return@launch
                }
                
                updateNotification("Connecting to ${enabledConfigs.size} configs...")
                
                logManager.addLog(LogLevel.INFO, TAG, "Starting frpc process...")
                val started = frpManager.startFrpc(configFile.absolutePath, { logLine ->
                    logManager.addFrpLog(logLine)
                }) { exitCode ->
                    // frpc 意外退出
                    logManager.addLog(LogLevel.ERROR, TAG, "frpc exited unexpectedly (code $exitCode)")
                    FrpStatusHolder.set(this@FrpService, FrpStatus.ERROR)
                    updateNotification("Error: frpc exited (code $exitCode)")
                }
                
                if (started) {
                    database.frpConfigDao().updateAllRunningStatus(false)
                    enabledConfigs.forEach { database.frpConfigDao().updateRunningStatus(it.id, true) }
                    FrpStatusHolder.set(this@FrpService, FrpStatus.RUNNING)
                    activeConfigName = "${enabledConfigs.size} configs"
                    updateNotification("FRP is running: ${enabledConfigs.size} configs")
                    startConnectionStatusMonitor()
                    logManager.addLog(LogLevel.INFO, TAG, "FRP started successfully")
                } else {
                    logManager.addLog(LogLevel.INFO, TAG, "No linked config found")
                    logManager.addLog(LogLevel.ERROR, TAG, "Failed to start FRP process")
                    FrpStatusHolder.set(this@FrpService, FrpStatus.ERROR)
                    updateNotification("Error: Failed to start")
                    delay(2000)
                    stopSelf()
                }
                
            } catch (e: Exception) {
                logManager.addLog(LogLevel.ERROR, TAG, "Error starting FRP: ${e.message}")
                Log.e(TAG, "Error starting FRP", e)
                FrpStatusHolder.set(this@FrpService, FrpStatus.ERROR)
                updateNotification("Error: ${e.message}")
                delay(2000)
                stopSelf()
            }
        }
    }
    
    private fun stopFrp() {
        serviceScope.launch {
            try {
                logManager.addLog(LogLevel.INFO, TAG, "Stopping FRP...")
                
                frpManager.stopFrpc()
                connectionStatusJob?.cancel()
                ConnectionStatusParser.getInstance().stop()
                ConnectionStatusParser.getInstance().reset()
                FrpStatusHolder.set(this@FrpService, FrpStatus.STOPPED)
                
                val database = AppDatabase.getDatabase(this@FrpService)
                database.frpConfigDao().updateAllRunningStatus(false)
                logManager.addLog(LogLevel.INFO, TAG, "All configs deactivated")
                
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                
                logManager.addLog(LogLevel.INFO, TAG, "FRP stopped")
            } catch (e: Exception) {
                logManager.addLog(LogLevel.ERROR, TAG, "Error stopping FRP: ${e.message}")
                Log.e(TAG, "Error stopping FRP", e)
            }
        }
    }
    
    // 连接状态监听：通知栏实时显示 P2P/中转
    private var connectionStatusJob: Job? = null
    private var activeConfigName: String = ""

    private fun startConnectionStatusMonitor() {
        ConnectionStatusParser.getInstance().start(logManager, serviceScope)
        connectionStatusJob?.cancel()
        connectionStatusJob = serviceScope.launch {
            ConnectionStatusParser.getInstance().status.collect { status ->
                if (status.type != ConnectionType.UNKNOWN) {
                    val subtitle = when (status.type) {
                        ConnectionType.P2P -> "P2P Direct"
                        ConnectionType.RELAY -> "Relay (STCP)"
                        ConnectionType.ERROR -> status.detail
                        ConnectionType.UNKNOWN -> ""
                    }
                    updateNotificationWithSubtitle("", subtitle)
                }
            }
        }
    }

    /**
     * 通知栏状态颜色映射（与主界面一致）：
     * P2P 绿 / 中转橙 / 错误红 / 其他灰
     */
    private fun notificationColor(): Int {
        val frpStatus = FrpStatusHolder.status.value
        val connType = ConnectionStatusParser.getInstance().status.value.type
        return when {
            frpStatus == FrpStatus.ERROR -> 0xFFF44336.toInt()
            connType == ConnectionType.P2P -> 0xFF4CAF50.toInt()
            connType == ConnectionType.RELAY -> 0xFFFF9800.toInt()
            else -> 0xFF9E9E9E.toInt()
        }
    }

    private fun createNotification(contentText: String, subtitle: String? = null): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, FrpService::class.java).apply {
                action = ACTION_STOP
            },
            PendingIntent.FLAG_IMMUTABLE
        )
        
        val builder = NotificationCompat.Builder(this, FrpApplication.CHANNEL_ID)
            .setContentTitle("FRP Service")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .addAction(R.drawable.ic_stop, "Stop", stopIntent)
            .setOngoing(true)
            .setColor(notificationColor())

        if (subtitle != null) {
            builder.setSubText(subtitle)
        }

        return builder.build()
    }
    
    private fun updateNotification(contentText: String) {
        val notification = createNotification(contentText)
        val notificationManager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    private fun updateNotificationWithSubtitle(title: String, subtitle: String) {
        val pendingIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this, 1, Intent(this, FrpService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, FrpApplication.CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .addAction(R.drawable.ic_stop, "Stop", stopIntent)
            .setOngoing(true)
            .setColor(notificationColor())
            .build()
        val nm = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        nm.notify(NOTIFICATION_ID, notification)
    }
    
    override fun onDestroy() {
        super.onDestroy()
        frpManager.cleanup()
        serviceScope.cancel()
        logManager.addLog(LogLevel.INFO, TAG, "Service destroyed")
    }
}
