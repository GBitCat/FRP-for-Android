package com.frp.frp_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 开机自启：系统启动完成后拉起 frpc 前台服务（服务内自动恢复上次运行状态） */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_LOCKED_BOOT_COMPLETED -> FrpcService.start(context)
        }
    }
}
