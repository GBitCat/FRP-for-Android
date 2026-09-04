package com.frp.frp_app

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/** Delivers a MethodChannel result on the main thread at most once. */
internal class MainThreadResult(
    private val delegate: MethodChannel.Result,
    private val onComplete: () -> Unit = {},
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val completed = AtomicBoolean(false)

    fun success(
        value: Any?,
        discardCleanup: () -> Unit = {},
        cleanup: () -> Unit = {},
    ) = dispatch(
        deliver = { delegate.success(value) },
        cleanup = cleanup,
        discardCleanup = discardCleanup,
    )

    fun error(code: String, message: String?, details: Any? = null) =
        dispatch(deliver = { delegate.error(code, message, details) })

    private fun dispatch(
        deliver: () -> Unit,
        cleanup: () -> Unit = {},
        discardCleanup: () -> Unit = {},
    ) {
        val completion = Runnable {
            if (!completed.compareAndSet(false, true)) {
                cleanupDiscarded(discardCleanup, cleanup)
                return@Runnable
            }
            try {
                deliver()
            } finally {
                try {
                    cleanup()
                } finally {
                    onComplete()
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            completion.run()
        } else if (!mainHandler.post(completion)) {
            if (!completed.compareAndSet(false, true)) {
                cleanupDiscarded(discardCleanup, cleanup)
                return
            }
            try {
                cleanupDiscarded(discardCleanup, cleanup)
            } finally {
                onComplete()
            }
        }
    }

    private fun cleanupDiscarded(discardCleanup: () -> Unit, cleanup: () -> Unit) {
        try {
            discardCleanup()
        } finally {
            cleanup()
        }
    }
}
