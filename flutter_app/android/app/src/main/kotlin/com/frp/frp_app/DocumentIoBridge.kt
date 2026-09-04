package com.frp.frp_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Arrays
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** Minimal Storage Access Framework bridge owned by the app. */
class DocumentIoBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "frp-document-io").apply { isDaemon = true }
    }
    private var pending: PendingRequest? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "pickFile" -> pickFile(
                        call.argument<List<String>>("mimeTypes").orEmpty(),
                        result,
                    )
                    "saveFile" -> saveFile(
                        requireNotNull(call.argument<String>("sourceFilePath")),
                        requireNotNull(call.argument<String>("fileName")),
                        call.argument<List<String>>("mimeTypes").orEmpty(),
                        result,
                    )
                    else -> result.notImplemented()
                }
            } catch (error: IllegalArgumentException) {
                result.error("INVALID_DOCUMENT_REQUEST", error.message, null)
            } catch (error: Exception) {
                result.error("DOCUMENT_IO_ERROR", error.message, null)
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val request = pending ?: return false
        if (requestCode != request.requestCode) return false
        if (request.dispatched) return true
        request.dispatched = true
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            request.completion.success(null)
            return true
        }
        val uri = data.data!!
        submit(request) {
            when (request) {
                is PendingRequest.Open -> copySelectedFile(uri)
                is PendingRequest.Save -> {
                    copyToDocument(request, uri)
                    uri.toString()
                }
            }
        }
        return true
    }

    fun close() {
        pending?.completion?.error(
            "DOCUMENT_IO_CANCELLED",
            "Activity closed before the document operation completed",
        )
        pending = null
        ioExecutor.shutdownNow()
        channel.setMethodCallHandler(null)
    }

    private fun pickFile(mimeTypes: List<String>, result: MethodChannel.Result) {
        val normalized = normalizeMimeTypes(mimeTypes)
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (normalized.size == 1) normalized.single() else "*/*"
            if (normalized.size > 1) {
                putExtra(Intent.EXTRA_MIME_TYPES, normalized.toTypedArray())
            }
        }
        val request = PendingRequest.Open()
        begin(request, result)
        try {
            activity.startActivityForResult(intent, REQUEST_OPEN)
        } catch (error: Exception) {
            request.completion.error("DOCUMENT_IO_ERROR", error.message)
        }
    }

    private fun saveFile(
        sourcePath: String,
        fileName: String,
        mimeTypes: List<String>,
        result: MethodChannel.Result,
    ) {
        require(isSafeFileName(fileName)) { "invalid export filename" }
        val requestedSource = File(sourcePath)
        val identity = managedExportIdentity(activity.cacheDir, requestedSource)
            ?: throw IllegalArgumentException("export source is not a managed cache file")
        val source = requestedSource.canonicalFile
        val mimeType = normalizeMimeTypes(mimeTypes).firstOrNull() ?: "application/octet-stream"
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        val request = PendingRequest.Save(source, identity)
        begin(request, result)
        try {
            activity.startActivityForResult(intent, REQUEST_SAVE)
        } catch (error: Exception) {
            request.completion.error("DOCUMENT_IO_ERROR", error.message)
        }
    }

    private fun begin(request: PendingRequest, result: MethodChannel.Result) {
        require(pending == null) { "another document operation is already active" }
        request.completion = MainThreadResult(result) {
            if (pending === request) pending = null
        }
        pending = request
    }

    private fun submit(request: PendingRequest, operation: () -> Any?) {
        try {
            ioExecutor.execute {
                try {
                    val value = operation()
                    request.completion.success(
                        value,
                        discardCleanup = {
                            if (request is PendingRequest.Open && value is String) {
                                deleteManagedImport(activity.cacheDir, value)
                            }
                        },
                    )
                } catch (error: IllegalArgumentException) {
                    request.completion.error("INVALID_DOCUMENT_REQUEST", error.message)
                } catch (error: Exception) {
                    request.completion.error("DOCUMENT_IO_ERROR", error.message)
                }
            }
        } catch (_: RejectedExecutionException) {
            request.completion.error(
                "DOCUMENT_IO_CANCELLED",
                "Activity is no longer available",
            )
        }
    }

    private fun copySelectedFile(uri: Uri): String {
        val directory = File(activity.cacheDir, "file_dialog-${UUID.randomUUID()}")
        check(directory.mkdir()) { "unable to create private import directory" }
        Os.chmod(directory.path, 448)
        val target = File(directory, "selected.bin")
        try {
            val input = activity.contentResolver.openInputStream(uri)
                ?: error("selected document could not be opened")
            input.use { source ->
                FileOutputStream(target).use { output ->
                    copyBounded(source, output)
                    output.fd.sync()
                }
            }
            Os.chmod(target.path, 384)
            return target.canonicalPath
        } catch (error: Exception) {
            target.delete()
            directory.delete()
            throw error
        }
    }

    private fun copyToDocument(request: PendingRequest.Save, uri: Uri) {
        openVerifiedManagedExportSource(
            activity.cacheDir,
            request.source,
            request.identity,
        ).use { input ->
            // Do not open or truncate the selected destination until the
            // post-picker source identity has been verified on its open FD.
            val output = activity.contentResolver.openOutputStream(uri, "wt")
                ?: error("selected destination could not be opened")
            output.use { destination ->
                copyVerifiedManagedExport(input, request.identity, destination)
                destination.flush()
            }
        }
    }

    private fun copyBounded(input: java.io.InputStream, output: java.io.OutputStream) {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        try {
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                require(total <= MAX_DOCUMENT_BYTES) { "document exceeds the 6 MiB limit" }
                output.write(buffer, 0, read)
            }
            require(total > 0) { "document is empty" }
        } finally {
            Arrays.fill(buffer, 0)
        }
    }

    private sealed class PendingRequest(
        val requestCode: Int,
    ) {
        lateinit var completion: MainThreadResult
        var dispatched: Boolean = false

        class Open : PendingRequest(REQUEST_OPEN)

        class Save(
            val source: File,
            val identity: ManagedExportIdentity,
        ) : PendingRequest(REQUEST_SAVE)
    }

    companion object {
        private const val CHANNEL_NAME = "com.frp.app/document_io"
        private const val REQUEST_OPEN = 6201
        private const val REQUEST_SAVE = 6202
        private const val MAX_DOCUMENT_BYTES = 6L * 1024L * 1024L
        private val MIME_TYPE = Regex("^[A-Za-z0-9.+*-]{1,64}/[A-Za-z0-9.+*-]{1,64}$")
        private val MANAGED_IMPORT_DIRECTORY = Regex(
            "^file_dialog-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-" +
                "[0-9a-f]{4}-[0-9a-f]{12}$",
        )
        // Directory.createTemp currently appends six random ASCII letters. A
        // slightly wider safe alphabet/length keeps this boundary compatible
        // with future Dart runtimes without accepting separators or dot names.
        private val MANAGED_EXPORT_DIRECTORY = Regex(
            "^frp_export-[A-Za-z0-9_-]{6,32}$",
        )

        internal fun isSafeFileName(name: String): Boolean =
            name.isNotBlank() &&
                name.length <= 128 &&
                name != "." &&
                name != ".." &&
                '/' !in name &&
                '\\' !in name &&
                name.none { it.isISOControl() }

        internal fun isWithin(root: File, candidate: File): Boolean =
            candidate.path == root.path || candidate.path.startsWith(root.path + File.separator)

        internal fun isManagedExportSource(cacheDirectory: File, requestedSource: File): Boolean =
            managedExportIdentity(cacheDirectory, requestedSource) != null

        internal data class ManagedExportIdentity(
            val device: Long,
            val inode: Long,
            val size: Long,
        )

        internal fun managedExportIdentity(
            cacheDirectory: File,
            requestedSource: File,
        ): ManagedExportIdentity? {
            return try {
                if (!isSafeFileName(requestedSource.name)) return null

                val requestedDirectory = requestedSource.parentFile ?: return null
                if (!requestedDirectory.isDirectory ||
                    OsConstants.S_ISLNK(Os.lstat(requestedDirectory.path).st_mode) ||
                    !MANAGED_EXPORT_DIRECTORY.matches(requestedDirectory.name)
                ) return null

                val cacheRoot = cacheDirectory.canonicalFile
                val managedDirectory = requestedDirectory.canonicalFile
                if (managedDirectory.parentFile?.canonicalFile != cacheRoot) return null

                val source = requestedSource.canonicalFile
                if (source.parentFile != managedDirectory || source.name != requestedSource.name) {
                    return null
                }
                val stat = Os.lstat(requestedSource.path)
                if (!OsConstants.S_ISREG(stat.st_mode) ||
                    stat.st_size !in 1L..MAX_DOCUMENT_BYTES
                ) return null
                ManagedExportIdentity(stat.st_dev, stat.st_ino, stat.st_size)
            } catch (_: Exception) {
                null
            }
        }

        internal fun openVerifiedManagedExportSource(
            cacheDirectory: File,
            requestedSource: File,
            expected: ManagedExportIdentity,
        ): FileInputStream {
            val pathIdentity = managedExportIdentity(cacheDirectory, requestedSource)
            require(pathIdentity == expected) {
                "export source changed while document picker was open"
            }
            val input = FileInputStream(requestedSource)
            try {
                val opened = Os.fstat(input.fd)
                require(
                    OsConstants.S_ISREG(opened.st_mode) &&
                        opened.st_size in 1L..MAX_DOCUMENT_BYTES &&
                        opened.st_dev == pathIdentity.device &&
                        opened.st_ino == pathIdentity.inode &&
                        opened.st_size == pathIdentity.size,
                ) { "export source changed while it was opened" }
                return input
            } catch (error: Exception) {
                input.close()
                throw error
            }
        }

        internal fun copyVerifiedManagedExport(
            input: FileInputStream,
            expected: ManagedExportIdentity,
            output: java.io.OutputStream,
        ) {
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            try {
                var total = 0L
                while (total < expected.size) {
                    val remaining = expected.size - total
                    val read = input.read(
                        buffer,
                        0,
                        minOf(buffer.size.toLong(), remaining).toInt(),
                    )
                    require(read >= 0) {
                        "export source was truncated while it was being read"
                    }
                    if (read == 0) continue
                    output.write(buffer, 0, read)
                    total += read
                }
                require(input.read() == -1) {
                    "export source grew while it was being read"
                }

                val after = Os.fstat(input.fd)
                require(
                    OsConstants.S_ISREG(after.st_mode) &&
                        after.st_dev == expected.device &&
                        after.st_ino == expected.inode &&
                        after.st_size == expected.size,
                ) { "export source changed while it was being read" }
            } finally {
                Arrays.fill(buffer, 0)
            }
        }

        internal fun deleteManagedImport(cacheDirectory: File, selectedPath: String) {
            try {
                val cacheRoot = cacheDirectory.canonicalFile
                val selected = File(selectedPath)
                if (selected.name != "selected.bin") return
                val managedDirectory = selected.parentFile?.canonicalFile ?: return
                if (managedDirectory.parentFile?.canonicalFile != cacheRoot ||
                    !MANAGED_IMPORT_DIRECTORY.matches(managedDirectory.name)
                ) return
                val canonicalSelected = selected.canonicalFile
                if (canonicalSelected.parentFile != managedDirectory) return
                canonicalSelected.delete()
                managedDirectory.delete()
            } catch (_: Exception) {
                // Best-effort cleanup must never broaden deletion scope.
            }
        }

        private fun normalizeMimeTypes(values: List<String>): List<String> =
            values.asSequence()
                .take(16)
                .filter { MIME_TYPE.matches(it) }
                .distinct()
                .toList()
                .ifEmpty { listOf("*/*") }
    }
}
