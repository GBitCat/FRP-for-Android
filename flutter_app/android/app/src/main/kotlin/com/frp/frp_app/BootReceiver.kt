package com.frp.frp_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** 开机恢复：仅在用户上次保持运行时拉起前台服务。 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON" -> FrpcService.ensureRunning(context)
        }
    }
}
