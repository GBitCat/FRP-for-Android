package com.frp.frp_app

import android.content.Context
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class FrpcServiceIntegrationTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @After
    fun stopService() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
    }

    @Test
    fun firstStartIsScheduledBeforeServiceInstanceExists() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        val config = writeConfig()

        assertTrue(FrpcService.start(context, config.absolutePath))
        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
    }

    @Test
    fun foregroundLifecycleRunsOnAndroid15Or16() {
        assumeTrue(Build.VERSION.SDK_INT == 35 || Build.VERSION.SDK_INT == 36)
        val config = writeConfig()

        assertTrue(FrpcService.start(context, config.absolutePath))
        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
        FrpcService.stop(context)
        assertTrue(waitUntil { FrpcService.instance == null })
    }

    @Test
    fun sensitiveConfigRoundTripsThroughAndroidKeystore() {
        val value = "token=\"secret-${System.nanoTime()}\""
        val first = SecureStringCodec.encrypt(value)
        val second = SecureStringCodec.encrypt(value)

        assertNotEquals(value, first)
        assertNotEquals(first, second)
        assertTrue(SecureStringCodec.decrypt(first) == value)
    }

    @Test
    fun blankConfigIsRejectedWithoutCreatingService() {
        FrpcService.stop(context)
        assertFalse(FrpcService.start(context, ""))
    }

    private fun writeConfig(): File = File(context.filesDir, "integration-frpc.toml").apply {
        writeText(
            """
            serverAddr = "127.0.0.1"
            serverPort = 1
            loginFailExit = false
            """.trimIndent()
        )
    }

    private fun waitUntil(timeoutMs: Long = 8_000, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(100)
        }
        return condition()
    }
}
