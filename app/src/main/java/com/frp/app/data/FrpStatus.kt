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
        val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, FrpStatus.STOPPED.name)
        _status.value = runCatching { FrpStatus.valueOf(saved!!) }.getOrDefault(FrpStatus.STOPPED)
    }

    fun set(context: Context, status: FrpStatus) {
        _status.value = status
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, status.name).apply()
    }
}
