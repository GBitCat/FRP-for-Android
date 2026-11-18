package com.frp.frp_app

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.File

/** Debug Flutter builds extract these files for the JIT. Release runs its AOT library instead. */
internal object LegacyFlutterAssets {
    fun cleanAfterUpdate(context: Context) {
        try {
            val state = context.getSharedPreferences("release_maintenance", Context.MODE_PRIVATE)
            val installedAt = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
            val key = "flutter_jit_assets_cleaned_at"
            if (state.getLong(key, -1L) == installedAt) return
            if (clean(File(context.dataDir, "app_flutter"))) {
                state.edit().putLong(key, installedAt).apply()
            }
        } catch (error: Exception) {
            Log.w("FrpEngine", "Could not complete Flutter asset cleanup", error)
        }
    }

    fun clean(flutterDataDir: File): Boolean {
        try {
            val assets = File(flutterDataDir, "flutter_assets")
            for (dir in listOf(flutterDataDir, assets)) {
                val mode = modeOf(dir) ?: return true
                if (!OsConstants.S_ISDIR(mode)) return false
            }
            for (name in listOf("kernel_blob.bin", "isolate_snapshot_data")) {
                val file = File(assets, name)
                val mode = modeOf(file) ?: continue
                if (OsConstants.S_ISREG(mode)) Os.remove(file.path)
            }
            return true
        } catch (_: ErrnoException) {
            // Leave the installation unmarked so the next launch can retry.
            return false
        }
    }

    private fun modeOf(file: File): Int? = try {
        Os.lstat(file.path).st_mode
    } catch (error: ErrnoException) {
        if (error.errno != OsConstants.ENOENT) throw error
        null
    }
}
