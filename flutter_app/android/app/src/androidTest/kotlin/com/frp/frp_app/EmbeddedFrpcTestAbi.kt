package com.frp.frp_app

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.io.DataInputStream
import java.io.File

/** Translated ARM64 may be advertised on x86 emulators that have the CI stub installed. */
internal fun hasArm64Frpc(): Boolean {
    val context: Context = ApplicationProvider.getApplicationContext()
    val executable = File(context.applicationInfo.nativeLibraryDir, "libfrpc.so")
    val header = ByteArray(20)
    DataInputStream(executable.inputStream()).use { it.readFully(header) }
    check(header.copyOfRange(0, 6).contentEquals(byteArrayOf(0x7f, 69, 76, 70, 2, 1))) {
        "Embedded frpc must be a little-endian ELF64 executable"
    }
    return when ((header[18].toInt() and 255) or ((header[19].toInt() and 255) shl 8)) {
        183 -> true  // EM_AARCH64
        62 -> false  // EM_X86_64 lifecycle fixture
        else -> error("Unsupported embedded frpc architecture")
    }
}
