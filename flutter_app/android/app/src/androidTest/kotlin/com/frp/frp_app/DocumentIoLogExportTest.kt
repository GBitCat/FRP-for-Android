package com.frp.frp_app

import android.content.Context
import android.system.Os
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID

/** Exercises log export admission without starting or stopping the service. */
@RunWith(AndroidJUnit4::class)
class DocumentIoLogExportTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @Test
    fun largeLogCopiesEveryByteThroughVerifiedStream() = withManagedDirectory { directory ->
        val source = File(directory, "frpc-logs-20261117-101530-filtered.txt")
        val block = ByteArray(8192) { ((it * 17) % 251).toByte() }
        val expectedDigest = MessageDigest.getInstance("SHA-256")
        val tail = "\n最后一行：日志完整结束\n".toByteArray(Charsets.UTF_8)
        FileOutputStream(source).use { output ->
            repeat(900) {
                output.write(block)
                expectedDigest.update(block)
            }
            output.write(tail)
            expectedDigest.update(tail)
            output.fd.sync()
        }
        assertTrue(source.length() > 6L * 1024L * 1024L)
        val identity = requireNotNull(DocumentIoBridge.managedExportIdentity(context.cacheDir, source))
        var copied = 0L
        val copiedDigest = MessageDigest.getInstance("SHA-256")
        val destination = object : OutputStream() {
            override fun write(value: Int) {
                copied++
                copiedDigest.update(value.toByte())
            }

            override fun write(buffer: ByteArray, offset: Int, length: Int) {
                copied += length
                copiedDigest.update(buffer, offset, length)
            }
        }
        DocumentIoBridge.openVerifiedManagedExportSource(context.cacheDir, source, identity).use { input ->
            DocumentIoBridge.copyVerifiedManagedExport(input, identity, destination)
        }
        assertEquals(source.length(), copied)
        assertArrayEquals(expectedDigest.digest(), copiedDigest.digest())
    }

    @Test
    fun largerLimitAppliesOnlyToGeneratedLogNamesAndRemainsBounded() = withManagedDirectory { directory ->
        val ordinaryLimit = 6L * 1024L * 1024L
        val logLimit = 32L * 1024L * 1024L
        for (name in listOf("backup.frpbackup", "anything.txt", "frpc-logs-20261117-101530-other.txt",
            "frpc-logs-20261117-101530.txt.zip", "frpc-logs-20261117-101530-filtered.TXT")) {
            val source = File(directory, name)
            RandomAccessFile(source, "rw").use { it.setLength(ordinaryLimit) }
            assertTrue(DocumentIoBridge.isManagedExportSource(context.cacheDir, source))
            RandomAccessFile(source, "rw").use { it.setLength(ordinaryLimit + 1) }
            assertFalse(DocumentIoBridge.isManagedExportSource(context.cacheDir, source))
            assertTrue(source.delete())
        }
        for (name in listOf("frpc-logs-20261117-101530.txt", "frpc-logs-20261117-101530-filtered.txt")) {
            val source = File(directory, name)
            RandomAccessFile(source, "rw").use { it.setLength(logLimit) }
            val identity = requireNotNull(DocumentIoBridge.managedExportIdentity(context.cacheDir, source))
            DocumentIoBridge.openVerifiedManagedExportSource(context.cacheDir, source, identity).use { input ->
                assertEquals(0, input.read())
            }
            RandomAccessFile(source, "rw").use { it.setLength(logLimit + 1) }
            assertNull(DocumentIoBridge.managedExportIdentity(context.cacheDir, source))
            assertThrows(IllegalArgumentException::class.java) {
                DocumentIoBridge.openVerifiedManagedExportSource(context.cacheDir, source, identity).close()
            }
            assertTrue(source.delete())
        }
    }

    @Test
    fun logNamesDoNotBypassDirectorySymlinkOrSourceIdentityChecks() = withManagedDirectory { directory ->
        val name = "frpc-logs-20261117-101530.txt"
        val source = File(directory, name)
        source.writeText("retained log\n")
        val identity = requireNotNull(DocumentIoBridge.managedExportIdentity(context.cacheDir, source))

        val nestedDirectory = File(directory, "nested").apply { mkdir() }
        val nestedSource = File(nestedDirectory, name).apply { writeText("nested\n") }
        assertNull(DocumentIoBridge.managedExportIdentity(context.cacheDir, nestedSource))

        val linkedSource = File(directory, "frpc-logs-20261117-101530-filtered.txt")
        Os.symlink(source.path, linkedSource.path)
        assertNull(DocumentIoBridge.managedExportIdentity(context.cacheDir, linkedSource))
        assertTrue(linkedSource.delete())

        val linkedDirectory = File(context.cacheDir, "frp_export-${UUID.randomUUID().toString().replace("-", "")}")
        try {
            Os.symlink(directory.path, linkedDirectory.path)
            assertNull(DocumentIoBridge.managedExportIdentity(context.cacheDir, File(linkedDirectory, name)))
        } finally {
            linkedDirectory.delete()
        }

        val replacement = File(directory, "replacement").apply { writeText("replacement log\n") }
        assertTrue(source.delete())
        assertTrue(replacement.renameTo(source))
        assertThrows(IllegalArgumentException::class.java) {
            DocumentIoBridge.openVerifiedManagedExportSource(context.cacheDir, source, identity).close()
        }
    }

    private fun withManagedDirectory(test: (File) -> Unit) {
        val directory = File(context.cacheDir, "frp_export-${UUID.randomUUID().toString().replace("-", "")}")
        check(directory.mkdir())
        try {
            test(directory)
        } finally {
            directory.deleteRecursively()
        }
    }
}
