package com.frp.app.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class FrpStatus { STOPPED, RUNNING, ERROR }

// 全局FRP状态持有者：Service写入，UI订阅；SharedPreferences持久化以跨进程重启恢复
object FrpStatusHolder {
    private const val PREFS = "frp_status"
    private const val KEY = "status"

    private val _status = MutableStateFlow(FrpStatus.STOPPED)
    val status: StateFlow<FrpStatus> = _status.asStateFlow()

    fun init(context: Context) {
        // 新进程启动时 frpc 必然未运行：若服务仍存活，其 onStartCommand 会重新置 RUNNING。
        // 不再从 prefs 恢复 RUNNING，避免"结束 app 后开关残留开启"（prefs 可能残留上次状态）。
        _status.value = FrpStatus.STOPPED
    }

    fun set(context: Context, status: FrpStatus) {
        _status.value = status
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, status.name).apply()
    }
}
