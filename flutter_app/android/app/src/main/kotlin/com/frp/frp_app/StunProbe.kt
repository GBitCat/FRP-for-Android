package com.frp.frp_app

import android.content.Context
import android.os.Build
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

internal data class StunProbeResult(
    val status: String,
    val exitCode: Int? = null,
    val detail: String,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "status" to status,
        "exitCode" to exitCode,
        "detail" to detail,
    )
}

/** One isolated CLI probe; it never reads or changes the foreground service's config. */
internal class StunProbeRunner(
    private val binary: File,
    private val temporaryDirectory: File,
    private val timeoutMillis: Long = 10_000,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val busy = AtomicBoolean(false)
    private val processLock = Any()
    private var activeProcess: Process? = null

    companion object {
        private const val MAX_OUTPUT_BYTES = 16 * 1024

        internal fun validEndpoint(endpoint: String?): Boolean {
            if (endpoint == null || endpoint.length > 21) return false
            val match = Regex("^([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.([0-9]+):([0-9]+)$")
                .matchEntire(endpoint) ?: return false
            for (i in 1..4) {
                val value = match.groupValues[i].toIntOrNull() ?: return false
                if (value !in 0..255 || value.toString() != match.groupValues[i]) return false
            }
            val port = match.groupValues[5].toIntOrNull() ?: return false
            return port in 1..65535 && port.toString() == match.groupValues[5]
        }
    }

    fun run(endpoint: String?): StunProbeResult {
        if (!validEndpoint(endpoint)) return StunProbeResult("error", detail = "A numeric IPv4 address and port are required")
        if (closed.get()) return StunProbeResult("error", detail = "STUN probe was cancelled")
        if (!busy.compareAndSet(false, true)) return StunProbeResult("error", detail = "A STUN probe is already running")
        var config: File? = null
        var process: Process? = null
        var reader: Thread? = null
        val output = ByteArrayOutputStream()
        try {
            check(binary.isFile && binary.canExecute()) { "The frpc executable is unavailable" }
            check(temporaryDirectory.isDirectory || temporaryDirectory.mkdirs()) { "STUN probe storage is unavailable" }
            config = File.createTempFile("frpc-stun-", ".toml", temporaryDirectory)
            config.setReadable(false, false)
            config.setWritable(false, false)
            check(config.setReadable(true, true) && config.setWritable(true, true)) { "Unable to protect STUN probe config" }
            config.writeText("serverAddr = \"127.0.0.1\"\nserverPort = 7000\nnatHoleStunServer = \"$endpoint\"\n")
            val launched = synchronized(processLock) {
                if (closed.get()) return StunProbeResult("error", detail = "STUN probe was cancelled")
                ProcessBuilder(
                    binary.absolutePath,
                    "nathole", "discover", "--strict_config=true",
                    "-c", config.absolutePath,
                    "--nat_hole_stun_server", endpoint!!,
                ).redirectErrorStream(true).start().also { activeProcess = it }
            }
            process = launched
            // Keep draining after the capture limit so a verbose child cannot block
            // on a full pipe. The CLI never receives credentials or user config.
            reader = Thread({
                try {
                    launched.inputStream.use { stream ->
                        val buffer = ByteArray(1024)
                        while (true) {
                            val size = stream.read(buffer)
                            if (size < 0) break
                            synchronized(output) {
                                val retained = minOf(size, MAX_OUTPUT_BYTES - output.size())
                                if (retained > 0) output.write(buffer, 0, retained)
                            }
                        }
                    }
                } catch (_: Exception) {
                    // Closing/cancelling the child also closes its output stream.
                }
            }, "frp-stun-output").apply { isDaemon = true; start() }
            val deadline = SystemClock.elapsedRealtime() + timeoutMillis
            var exitCode: Int? = null
            while (!closed.get() && SystemClock.elapsedRealtime() < deadline) {
                exitCode = exitCodeOrNull(launched)
                if (exitCode != null) break
                Thread.sleep(25)
            }
            if (closed.get()) return StunProbeResult("error", detail = "STUN probe was cancelled")
            if (exitCode == null) return StunProbeResult("timeout", detail = "STUN probe exceeded its ${timeoutMillis} ms deadline")
            reader.join(500)
            val captured = synchronized(output) { output.toString(Charsets.UTF_8.name()).trim() }
            val detail = captured.take(2048)
            return when {
                exitCode == 0 -> StunProbeResult("reachable", exitCode, detail)
                captured.contains("wait response from stun server timeout", ignoreCase = true) ->
                    StunProbeResult("timeout", exitCode, detail)
                else -> StunProbeResult("error", exitCode, detail.ifEmpty { "STUN discovery failed" })
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return StunProbeResult("error", detail = "STUN probe was cancelled")
        } catch (error: Exception) {
            return StunProbeResult("error", detail = error.message?.take(512) ?: "STUN probe failed")
        } finally {
            process?.let { child ->
                terminate(child)
                runCatching { child.inputStream.close() }
                runCatching { child.outputStream.close() }
                runCatching { child.errorStream.close() }
                synchronized(processLock) { if (activeProcess === child) activeProcess = null }
            }
            runCatching { reader?.join(500) }
            config?.delete()
            busy.set(false)
        }
    }

    override fun close() {
        closed.set(true)
        synchronized(processLock) { activeProcess?.let(::terminate) }
    }

    private fun exitCodeOrNull(process: Process): Int? = try {
        process.exitValue()
    } catch (_: IllegalThreadStateException) {
        null
    }

    private fun terminate(process: Process) {
        if (exitCodeOrNull(process) != null) return
        process.destroy()
        if (Build.VERSION.SDK_INT >= 26 && exitCodeOrNull(process) == null) {
            process.destroyForcibly()
        }
    }
}

/** Activity-owned bridge: exactly one outstanding request and no unbounded queue. */
internal class StunProbeBridge(
    context: Context,
    private val report: (String) -> Unit = {},
) : AutoCloseable {
    private val runner = StunProbeRunner(
        File(context.applicationInfo.nativeLibraryDir, "libfrpc.so"),
        context.cacheDir,
    )
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "frp-stun-probe").apply { isDaemon = true }
    }
    private val pending = AtomicReference<MainThreadResult?>()

    fun probe(endpoint: String?, result: MethodChannel.Result) {
        lateinit var completion: MainThreadResult
        completion = MainThreadResult(result) { pending.compareAndSet(completion, null) }
        if (!pending.compareAndSet(null, completion)) {
            completion.success(StunProbeResult("error", detail = "A STUN probe is already running").toMap())
            return
        }
        try {
            executor.execute {
                val validEndpoint = StunProbeRunner.validEndpoint(endpoint)
                val started = SystemClock.elapsedRealtime()
                if (validEndpoint) report("[STUN] Probing $endpoint")
                val outcome = runner.run(endpoint)
                if (validEndpoint) {
                    val elapsed = SystemClock.elapsedRealtime() - started
                    val weight = if (outcome.status == "reachable" && outcome.exitCode == 0) 1 else 0
                    report("[STUN] $endpoint: ${outcome.status}; weight=$weight; ${elapsed}ms")
                }
                completion.success(outcome.toMap())
            }
        } catch (_: RejectedExecutionException) {
            completion.success(StunProbeResult("error", detail = "STUN probe was cancelled").toMap())
        }
    }

    override fun close() {
        runner.close()
        executor.shutdownNow()
        pending.getAndSet(null)?.success(StunProbeResult("error", detail = "STUN probe was cancelled").toMap())
    }
}
