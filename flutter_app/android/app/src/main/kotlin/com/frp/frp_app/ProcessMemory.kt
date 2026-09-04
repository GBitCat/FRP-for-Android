package com.frp.frp_app

import android.system.Os
import android.system.OsConstants
import java.io.File

/** Reads process RSS using the device's actual kernel page size. */
internal object ProcessMemory {
    private const val FALLBACK_PAGE_SIZE_BYTES = 4096L

    internal fun pageSizeBytes(): Long = try {
        Os.sysconf(OsConstants._SC_PAGESIZE).takeIf { it > 0 }
            ?: FALLBACK_PAGE_SIZE_BYTES
    } catch (_: Exception) {
        FALLBACK_PAGE_SIZE_BYTES
    }

    internal fun rssMb(pid: Int): Double = try {
        val statm = File("/proc/$pid/statm").readText().trim().split(Regex("\\s+"))
        val residentPages = statm.getOrNull(1)?.toLongOrNull() ?: 0L
        residentPages * pageSizeBytes().toDouble() / 1024.0 / 1024.0
    } catch (_: Exception) {
        0.0
    }
}
