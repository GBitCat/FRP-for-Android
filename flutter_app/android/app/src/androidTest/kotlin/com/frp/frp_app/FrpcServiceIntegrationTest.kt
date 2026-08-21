package com.frp.frp_app

import android.content.Context
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

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
        val config = configText()

        assertTrue(FrpcService.start(context, config))
        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
    }

    @Test
    fun immediateStopRevokesQueuedFirstStart() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }

        assertTrue(FrpcService.start(context, configText()))
        FrpcService.stop(context)

        Thread.sleep(1_000)
        assertTrue(FrpcService.instance?.isFrpcRunning() != true)
    }

    @Test
    fun foregroundLifecycleRunsOnAndroid15Or16() {
        assumeTrue(Build.VERSION.SDK_INT == 35 || Build.VERSION.SDK_INT == 36)
        val config = configText()

        assertTrue(FrpcService.start(context, config))
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
    fun passwordBackupIsAuthenticatedAndPortableEnvelopeIsRandomized() {
        val value = "secret backup".toByteArray()
        val password = "correct horse battery staple"
        val first = BackupCipher.encrypt(value, password)
        val second = BackupCipher.encrypt(value, password)

        assertFalse(first.contentEquals(second))
        assertTrue(BackupCipher.decrypt(first, password).contentEquals(value))
        try {
            BackupCipher.decrypt(first, "wrong password value")
            throw AssertionError("wrong password was accepted")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun blankConfigIsRejectedWithoutCreatingService() {
        FrpcService.stop(context)
        assertFalse(FrpcService.start(context, ""))
    }

    @Test
    fun sensitiveFrpcLogFieldsAreRedacted() {
        val line = "token = \"one\" secretKey=two password:three clientSecret=four"
        assertEquals(
            "token=*** secretKey=*** password=*** clientSecret=***",
            FrpcService.redactLogLine(line)
        )
    }

    @Test
    fun userStopDeletesPrivateRuntimeConfig() {
        val config = configText()
        assertTrue(FrpcService.start(context, config))
        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })

        FrpcService.stop(context)

        assertTrue(waitUntil { FrpcService.instance == null })
        assertFalse(FrpcService.runtimeConfigFile(context).exists())
    }

    @Test
    fun runtimeConfigIsDeletedAfterFrpcReadsIt() {
        assertTrue(FrpcService.start(context, configText()))
        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
        assertTrue(waitUntil { !FrpcService.runtimeConfigFile(context).exists() })
    }

    private fun configText(): String =
        """
            serverAddr = "127.0.0.1"
            serverPort = 1
            loginFailExit = false
        """.trimIndent()

    private fun waitUntil(timeoutMs: Long = 8_000, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(100)
        }
        return condition()
    }
}
