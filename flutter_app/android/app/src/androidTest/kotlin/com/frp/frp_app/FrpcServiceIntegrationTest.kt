package com.frp.frp_app

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Looper
import android.view.WindowManager
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.StringReader
import java.util.Arrays
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class FrpcServiceIntegrationTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    @After
    fun stopService() {
        FrpcService.beforeStartWorkerForTest = null
        FrpcService.beforeStopWorkerForTest = null
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
    fun failedInitialStartCommitCannotScheduleOrLeaveGhostRunIntent() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        assertFalse(FrpcService.isRunRequested(context))

        val started = FrpcService.startWithCommitForTest(
            context,
            configText(),
        ) { editor ->
            // Apply the pending intent to both memory and disk, then emulate
            // commit() reporting failure. Production must restore the exact
            // previous state before returning to Dart.
            assertTrue(editor.commit())
            false
        }

        assertFalse(started)
        assertFalse(FrpcService.isRunRequested(context))
        Thread.sleep(500)
        assertTrue(FrpcService.instance == null)
        FrpcService.ensureRunning(context)
        Thread.sleep(500)
        assertTrue(FrpcService.instance == null)
        assertFalse(FrpcService.isRunRequested(context))
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
    fun redeliveredStartRecoversPendingOrLatestCommittedIntentOnly() {
        assertEquals(
            StartRequestDisposition.START_PENDING,
            FrpcService.classifyStartRequest(
                desired = true,
                pendingRequestId = "request-1",
                encryptedPayload = null,
                deliveredRequestId = "request-1",
            ),
        )
        assertEquals(
            StartRequestDisposition.RESTORE_COMMITTED,
            FrpcService.classifyStartRequest(
                desired = true,
                pendingRequestId = null,
                encryptedPayload = "encrypted-latest-config",
                deliveredRequestId = "historical-request",
            ),
        )
        assertEquals(
            StartRequestDisposition.REJECT,
            FrpcService.classifyStartRequest(
                desired = true,
                pendingRequestId = "newer-request",
                encryptedPayload = "encrypted-old-config",
                deliveredRequestId = "historical-request",
            ),
        )
        assertEquals(
            StartRequestDisposition.REJECT,
            FrpcService.classifyStartRequest(
                desired = false,
                pendingRequestId = null,
                encryptedPayload = null,
                deliveredRequestId = "historical-request",
            ),
        )
    }

    @Test
    fun rejectedOlderStartDoesNotCancelNewerQueuedStart() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }

        assertTrue(FrpcService.start(context, configText()))
        assertTrue(FrpcService.start(context, configText()))

        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
    }

    @Test
    fun rapidStartStopStartKeepsNewestStartRunning() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }

        assertTrue(FrpcService.start(context, configText()))
        FrpcService.stop(context)
        assertTrue(FrpcService.start(context, configText()))

        assertTrue(waitUntil(timeoutMs = 15_000) {
            FrpcService.instance?.isFrpcRunning() == true
        })
    }

    @Test
    fun nativeRunIntentTracksQueuedRunningAndStoppedStates() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        assertFalse(FrpcService.isRunRequested(context))

        assertTrue(FrpcService.start(context, configText()))
        assertTrue(FrpcService.isRunRequested(context))
        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
        assertTrue(FrpcService.isRunRequested(context))

        FrpcService.stop(context)
        assertFalse(FrpcService.isRunRequested(context))
        assertTrue(waitUntil { FrpcService.instance == null })
        assertFalse(FrpcService.isRunRequested(context))
    }

    @Test
    fun stopAfterAcceptedStartBeforeWorkerCannotReviveRunIntent() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        val workerEntered = CountDownLatch(1)
        val releaseWorker = CountDownLatch(1)
        FrpcService.beforeStartWorkerForTest = {
            workerEntered.countDown()
            releaseWorker.await(5, TimeUnit.SECONDS)
        }

        try {
            assertTrue(FrpcService.start(context, configText()))
            assertTrue(workerEntered.await(3, TimeUnit.SECONDS))
            assertTrue(FrpcService.isRunRequested(context))

            FrpcService.stop(context)
            assertFalse(FrpcService.isRunRequested(context))
        } finally {
            FrpcService.beforeStartWorkerForTest = null
            releaseWorker.countDown()
        }

        assertTrue(waitUntil { FrpcService.instance == null })
        assertFalse(FrpcService.isRunRequested(context))
    }

    @Test
    fun stopIntentIsFalseWhileLiveProcessCleanupIsStillQueued() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        assertTrue(FrpcService.start(context, configText()))
        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
        val service = requireNotNull(FrpcService.instance)
        val workerEntered = CountDownLatch(1)
        val releaseWorker = CountDownLatch(1)
        FrpcService.beforeStopWorkerForTest = {
            workerEntered.countDown()
            releaseWorker.await(5, TimeUnit.SECONDS)
        }

        try {
            FrpcService.stop(context)
            assertFalse(FrpcService.isRunRequested(context))
            assertTrue(workerEntered.await(3, TimeUnit.SECONDS))
            assertTrue(service.isFrpcRunning())
            assertFalse(FrpcService.isRunRequested(context))
        } finally {
            FrpcService.beforeStopWorkerForTest = null
            releaseWorker.countDown()
        }

        assertTrue(waitUntil { FrpcService.instance == null })
    }

    @Test
    fun failedStopCommitRestoresQueuedRunIntentAndDoesNotStopService() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        val workerEntered = CountDownLatch(1)
        val releaseWorker = CountDownLatch(1)
        FrpcService.beforeStartWorkerForTest = {
            workerEntered.countDown()
            releaseWorker.await(5, TimeUnit.SECONDS)
        }

        try {
            assertTrue(FrpcService.start(context, configText()))
            assertTrue(workerEntered.await(3, TimeUnit.SECONDS))
            assertTrue(FrpcService.isRunRequested(context))

            val stopped = FrpcService.stopWithCommitForTest(context) { editor ->
                // SharedPreferences mutates its in-process map before reporting
                // the disk result. Reproduce that state transition, then report
                // failure so production rollback semantics are exercised.
                assertTrue(editor.commit())
                false
            }
            assertFalse(stopped)
            assertTrue(FrpcService.isRunRequested(context))
        } finally {
            FrpcService.beforeStartWorkerForTest = null
            releaseWorker.countDown()
        }

        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
        assertTrue(FrpcService.isRunRequested(context))
    }

    @Test
    fun failedAbandonCommitRestoresCompleteRunningIntent() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        assertTrue(FrpcService.start(context, configText()))
        assertTrue(waitUntil { FrpcService.instance?.isFrpcRunning() == true })
        assertTrue(FrpcService.isRunRequested(context))

        val abandoned = FrpcService.abandonRunIntentIfCurrentForTest(
            context,
            requestId = null,
        ) { editor ->
            assertTrue(editor.commit())
            false
        }

        assertFalse(abandoned)
        assertTrue(FrpcService.isRunRequested(context))
        assertTrue(FrpcService.instance?.isFrpcRunning() == true)
    }

    @Test
    fun failedStopDeliveryOnlyStopsAnUnsupersededIdleService() {
        assertTrue(FrpcService.shouldStopAfterFallback(7, 7, false, null))
        assertFalse(FrpcService.shouldStopAfterFallback(7, 8, false, null))
        assertFalse(FrpcService.shouldStopAfterFallback(7, 7, true, null))
        assertFalse(FrpcService.shouldStopAfterFallback(7, 7, false, "new-start"))
    }

    @Test
    fun missingRecoveryPayloadStopsForegroundService() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        val prefs = context.getSharedPreferences("frp_state", Context.MODE_PRIVATE)
        assertTrue(
            prefs.edit()
                .putBoolean("was_running", true)
                .remove("last_config_payload")
                .commit(),
        )

        FrpcService.ensureRunning(context)

        assertTrue(
            waitUntil {
                !prefs.getBoolean("was_running", true) && FrpcService.instance == null
            },
        )
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
    fun secureCodecRejectsOversizedPlaintextAndEncodedPayload() {
        try {
            SecureStringCodec.encrypt("x".repeat(SecureStringCodec.MAX_PLAINTEXT_BYTES + 1))
            throw AssertionError("oversized plaintext was accepted")
        } catch (_: IllegalArgumentException) {
            // expected
        }
        try {
            SecureStringCodec.decrypt(
                "A".repeat(SecureStringCodec.MAX_ENCODED_PAYLOAD_CHARS + 1),
            )
            throw AssertionError("oversized encrypted payload was accepted")
        } catch (_: IllegalArgumentException) {
            // expected
        }
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
    fun passwordBackupRejectsOversizedPasswords() {
        try {
            BackupCipher.encrypt("secret".toByteArray(), "x".repeat(1_025))
            throw AssertionError("oversized password was accepted")
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
        val line = "token = \"one\" secretKey=two password:three clientSecret=four " +
            "passwd=five credential=six apiKey=seven private_key=eight access-key=nine " +
            "cookie=ten sk=eleven Authorization: Bearer twelve"
        val redacted = FrpcService.redactLogLine(line)
        assertEquals(
            "token=*** secretKey=*** password=*** clientSecret=*** passwd=*** " +
                "credential=*** apiKey=*** private_key=*** access-key=*** cookie=*** " +
                "sk=*** Authorization=***",
            redacted
        )
        for (secret in listOf("one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve")) {
            assertFalse(redacted.contains(secret))
        }
    }

    @Test
    fun jsonFrpcLogFieldsAreRedactedWithoutBreakingQuotedKeys() {
        val line = """{"token":"one","nested":{"password":"two"},"authorization":"Bearer three","message":"safe"}"""
        val redacted = FrpcService.redactLogLine(line)

        assertEquals(
            """{"token":"***","nested":{"password":"***"},"authorization":"***","message":"safe"}""",
            redacted,
        )
        for (secret in listOf("one", "two", "three")) {
            assertFalse(redacted.contains(secret))
        }
    }

    @Test
    fun unquotedCredentialValuesWithSpacesAreFullyRedacted() {
        val line = "token = alpha beta; message=safe, " +
            "Authorization: Bearer gamma delta; password: epsilon zeta"

        assertEquals(
            "token=***; message=safe, Authorization=***; password=***",
            FrpcService.redactLogLine(line),
        )
    }

    @Test
    fun oversizedLogLinesAreBoundedBeforeRedactionWithoutLeakingCredentials() {
        val ordinary = FrpcService.sanitizeLogLine("x".repeat(8_192))
        assertTrue(ordinary.length <= 4_096)
        assertTrue(ordinary.endsWith("[truncated]"))

        val secret = "do-not-retain-${System.nanoTime()}"
        val credentialNearBoundary = "x".repeat(4_050) + " token = Bearer $secret extra"
        val redacted = FrpcService.sanitizeLogLine(credentialNearBoundary)
        assertTrue(redacted.length <= 4_096)
        assertFalse(redacted.contains(secret))
        assertTrue(redacted.contains("token=***"))
    }

    @Test
    fun logReaderBoundsPhysicalLinesAndRecoversAtEveryLineEnding() {
        val lines = mutableListOf<String>()
        val oversized = "x".repeat(1_000_000)

        FrpcService.readBoundedLogLines(
            StringReader("first\r\nsecond\rthird\n$oversized\nlast"),
        ) { lines += it }

        assertEquals(5, lines.size)
        assertEquals(listOf("first", "second", "third"), lines.take(3))
        assertTrue(lines[3].length <= 4_096)
        assertTrue(lines[3].endsWith("[truncated]"))
        assertEquals("last", lines[4])
    }

    @Test
    fun logReaderEmitsOneBoundedLineForOversizedEofWithoutNewline() {
        val lines = mutableListOf<String>()

        FrpcService.readBoundedLogLines(StringReader("y".repeat(1_000_000))) {
            lines += it
        }

        assertEquals(1, lines.size)
        assertTrue(lines.single().length <= 4_096)
        assertTrue(lines.single().endsWith("[truncated]"))
    }

    @Test
    fun appStatusMapRejectsNewNamesAtLimitButAllowsExistingUpdates() {
        val statuses = mutableMapOf<String, String>()
        assertTrue(FrpcService.recordBoundedAppStatus(statuses, "first", "relay", 2))
        assertTrue(FrpcService.recordBoundedAppStatus(statuses, "second", "p2p", 2))
        assertFalse(FrpcService.recordBoundedAppStatus(statuses, "third", "error", 2))
        assertTrue(FrpcService.recordBoundedAppStatus(statuses, "first", "p2p", 2))
        assertEquals(mapOf("first" to "p2p", "second" to "p2p"), statuses)
    }

    @Test
    fun stunEndpointParsingHandlesIpv4DnsAndIpv6() {
        assertEquals(
            "stun.example.com:3479",
            FrpcService.parseStunEndpoint("stun.example.com:3479")?.authority(),
        )
        assertEquals(
            "192.0.2.1:3478",
            FrpcService.parseStunEndpoint("192.0.2.1")?.authority(),
        )
        assertEquals(
            "[2001:db8::1]:3479",
            FrpcService.parseStunEndpoint("[2001:db8::1]:3479")?.authority(),
        )
        assertEquals(
            "[2001:db8::1]:3478",
            FrpcService.parseStunEndpoint("2001:db8::1")?.authority(),
        )
        assertEquals(null, FrpcService.parseStunEndpoint("[2001:db8::1]:0"))
        assertEquals(null, FrpcService.parseStunEndpoint("[not:ipv6]:3478"))
        assertEquals(null, FrpcService.parseStunEndpoint("not:an:ipv6"))
        assertEquals(null, FrpcService.parseStunEndpoint("host:65536"))
        assertEquals(null, FrpcService.parseStunEndpoint("host:03"))
    }

    @Test
    fun malformedConfigCanTriggerOnlyOneStunDnsLookup() {
        val config = (1..100).joinToString("\n") {
            "natHoleStunServer = \"stun$it.example.test:3478\""
        }
        val lookups = AtomicInteger(0)

        val patched = FrpcService.patchFirstStunEndpoint(config) { host ->
            lookups.incrementAndGet()
            if (host == "stun1.example.test") "192.0.2.1" else "192.0.2.2"
        }

        assertEquals(1, lookups.get())
        assertTrue(patched.startsWith("natHoleStunServer = \"192.0.2.1:3478\"\n"))
        assertTrue(patched.contains("natHoleStunServer = \"stun2.example.test:3478\""))
        assertTrue(patched.endsWith("natHoleStunServer = \"stun100.example.test:3478\""))
    }

    @Test
    fun debugActivityAllowsCaptureWhileReleasePolicyRemainsSecure() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                assertFalse(
                    (activity.window.attributes.flags and
                        WindowManager.LayoutParams.FLAG_SECURE) != 0
                )
                assertFalse(
                    ScreenCapturePolicy.shouldProtect(ApplicationInfo.FLAG_DEBUGGABLE)
                )
                assertTrue(ScreenCapturePolicy.shouldProtect(0))
            }
        }
    }

    @Test
    fun documentBridgeRejectsUnsafeNamesAndPathPrefixCollisions() {
        for (name in listOf("", ".", "..", "../secret", "dir/file", "dir\\file", "bad\u0000name", "bad\nname")) {
            assertFalse(DocumentIoBridge.isSafeFileName(name))
        }
        assertTrue(DocumentIoBridge.isSafeFileName("frp backup-设备.frptls"))

        val root = File(context.cacheDir, "exports").canonicalFile
        assertTrue(DocumentIoBridge.isWithin(root, File(root, "bundle.zip").canonicalFile))
        assertFalse(
            DocumentIoBridge.isWithin(
                root,
                File(context.cacheDir, "exports-escape/bundle.zip").canonicalFile,
            ),
        )
    }

    @Test
    fun documentBridgeExportsOnlyManagedDirectCacheFiles() {
        val suffix = UUID.randomUUID().toString().replace("-", "").take(12)
        val linkSuffix = UUID.randomUUID().toString().replace("-", "").take(12)
        val managedDirectory = File(context.cacheDir, "frp_export-$suffix")
        val managedFile = File(managedDirectory, "bundle.frptls")
        val nestedDirectory = File(managedDirectory, "nested")
        val nestedFile = File(nestedDirectory, "bundle.frptls")
        val otherPrivateFile = File(context.noBackupFilesDir, "document-test-$suffix.key")
        val prefixCollisionDirectory = File(context.cacheDir, "frp_export.$suffix")
        val prefixCollisionFile = File(prefixCollisionDirectory, "bundle.frptls")
        val replacementFile = File(managedDirectory, "replacement.tmp")
        val linkedFile = File(managedDirectory, "linked.frptls")
        val linkedDirectory = File(context.cacheDir, "frp_export-$linkSuffix")
        try {
            assertTrue(managedDirectory.mkdir())
            assertTrue(nestedDirectory.mkdir())
            managedFile.writeText("public export")
            nestedFile.writeText("nested")
            otherPrivateFile.writeText("private")
            assertTrue(prefixCollisionDirectory.mkdir())
            prefixCollisionFile.writeText("collision")

            assertTrue(DocumentIoBridge.isManagedExportSource(context.cacheDir, managedFile))
            assertFalse(DocumentIoBridge.isManagedExportSource(context.cacheDir, nestedFile))
            assertFalse(DocumentIoBridge.isManagedExportSource(context.cacheDir, otherPrivateFile))
            assertFalse(
                DocumentIoBridge.isManagedExportSource(context.cacheDir, prefixCollisionFile),
            )

            android.system.Os.symlink(otherPrivateFile.path, linkedFile.path)
            assertFalse(DocumentIoBridge.isManagedExportSource(context.cacheDir, linkedFile))
            android.system.Os.symlink(managedDirectory.path, linkedDirectory.path)
            assertFalse(
                DocumentIoBridge.isManagedExportSource(
                    context.cacheDir,
                    File(linkedDirectory, managedFile.name),
                ),
            )

            val originalIdentity = requireNotNull(
                DocumentIoBridge.managedExportIdentity(context.cacheDir, managedFile),
            )
            DocumentIoBridge.openVerifiedManagedExportSource(
                context.cacheDir,
                managedFile,
                originalIdentity,
            ).use { input ->
                assertEquals("public export", input.reader().readText())
            }

            DocumentIoBridge.openVerifiedManagedExportSource(
                context.cacheDir,
                managedFile,
                originalIdentity,
            ).use { input ->
                var resized = false
                val destination = object : ByteArrayOutputStream() {
                    override fun write(buffer: ByteArray, offset: Int, length: Int) {
                        super.write(buffer, offset, length)
                        if (!resized) {
                            resized = true
                            FileOutputStream(managedFile, false).use { changed ->
                                changed.write('x'.code)
                                changed.fd.sync()
                            }
                        }
                    }
                }
                var inPlaceResizeRejected = false
                try {
                    DocumentIoBridge.copyVerifiedManagedExport(
                        input,
                        originalIdentity,
                        destination,
                    )
                } catch (_: IllegalArgumentException) {
                    inPlaceResizeRejected = true
                }
                assertTrue(inPlaceResizeRejected)
                val resizedStat = android.system.Os.lstat(managedFile.path)
                assertEquals(originalIdentity.inode, resizedStat.st_ino)
                assertEquals(1L, resizedStat.st_size)
            }

            managedFile.writeText("public export")

            replacementFile.writeText("replacement content must never be exported")
            assertTrue(managedFile.delete())
            assertTrue(replacementFile.renameTo(managedFile))
            var replacementRejected = false
            try {
                DocumentIoBridge.openVerifiedManagedExportSource(
                    context.cacheDir,
                    managedFile,
                    originalIdentity,
                ).use { }
            } catch (_: IllegalArgumentException) {
                replacementRejected = true
            }
            assertTrue(replacementRejected)
        } finally {
            linkedFile.delete()
            linkedDirectory.delete()
            replacementFile.delete()
            nestedFile.delete()
            nestedDirectory.delete()
            managedFile.delete()
            managedDirectory.delete()
            prefixCollisionFile.delete()
            prefixCollisionDirectory.delete()
            otherPrivateFile.delete()
        }
    }

    @Test
    fun channelResultCompletesOnMainThreadAtMostOnce() {
        val callbackCount = AtomicInteger(0)
        val completionCount = AtomicInteger(0)
        val callbackLooper = AtomicReference<Looper?>()
        val callbackValue = AtomicReference<Any?>()
        val callbackLatch = CountDownLatch(1)
        val result = object : MethodChannel.Result {
            override fun success(result: Any?) {
                callbackCount.incrementAndGet()
                callbackLooper.set(Looper.myLooper())
                callbackValue.set(result)
                callbackLatch.countDown()
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                callbackCount.incrementAndGet()
                callbackLooper.set(Looper.myLooper())
                callbackLatch.countDown()
            }

            override fun notImplemented() {
                callbackCount.incrementAndGet()
                callbackLooper.set(Looper.myLooper())
                callbackLatch.countDown()
            }
        }
        val completion = MainThreadResult(result) { completionCount.incrementAndGet() }

        Thread {
            completion.success("first")
            completion.error("LATE_RESULT", "must be ignored")
        }.start()

        assertTrue(callbackLatch.await(3, TimeUnit.SECONDS))
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertEquals(1, callbackCount.get())
        assertEquals(1, completionCount.get())
        assertEquals("first", callbackValue.get())
        assertEquals(Looper.getMainLooper(), callbackLooper.get())
    }

    @Test
    fun channelResultCleansDeliveredAndDiscardedByteArrays() {
        val callbackCount = AtomicInteger(0)
        val completionCount = AtomicInteger(0)
        val cleanupCount = AtomicInteger(0)
        val deliveredCopy = AtomicReference<ByteArray>()
        val callbackLatch = CountDownLatch(1)
        val result = object : MethodChannel.Result {
            override fun success(result: Any?) {
                callbackCount.incrementAndGet()
                deliveredCopy.set((result as ByteArray).clone())
                callbackLatch.countDown()
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
                throw AssertionError("unexpected error result")

            override fun notImplemented() = throw AssertionError("unexpected missing method")
        }
        val first = byteArrayOf(1, 2, 3)
        val late = byteArrayOf(4, 5, 6)
        val completion = MainThreadResult(result) { completionCount.incrementAndGet() }

        Thread {
            completion.success(first) {
                Arrays.fill(first, 0)
                cleanupCount.incrementAndGet()
            }
            completion.success(late) {
                Arrays.fill(late, 0)
                cleanupCount.incrementAndGet()
            }
        }.start()

        assertTrue(callbackLatch.await(3, TimeUnit.SECONDS))
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertEquals(1, callbackCount.get())
        assertEquals(1, completionCount.get())
        assertEquals(2, cleanupCount.get())
        assertTrue(deliveredCopy.get().contentEquals(byteArrayOf(1, 2, 3)))
        assertTrue(first.all { it == 0.toByte() })
        assertTrue(late.all { it == 0.toByte() })
    }

    @Test
    fun cancelledQueuedSecureTaskWipesOwnedInputWithoutRunning() {
        val operationCount = AtomicInteger(0)
        val cleanupCount = AtomicInteger(0)
        val queuedInput = byteArrayOf(1, 2, 3, 4)
        val blockerStarted = CountDownLatch(1)
        val releaseBlocker = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        val task = CancellableSecureTask(
            operation = { operationCount.incrementAndGet() },
            cleanup = {
                Arrays.fill(queuedInput, 0)
                cleanupCount.incrementAndGet()
            },
        )

        try {
            executor.execute {
                blockerStarted.countDown()
                try {
                    releaseBlocker.await()
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
            assertTrue(blockerStarted.await(3, TimeUnit.SECONDS))
            executor.execute(task)

            val queued = executor.shutdownNow()
            assertTrue(queued.contains(task))
            assertEquals(1, cancelQueuedSecureTasks(queued))
            task.run()
            assertFalse(task.cancelBeforeRun())
            assertEquals(0, operationCount.get())
            assertEquals(1, cleanupCount.get())
            assertTrue(queuedInput.all { it == 0.toByte() })
        } finally {
            releaseBlocker.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS))
        }
    }

    @Test
    fun discardedDocumentImportIsDeletedButDeliveredImportRemains() {
        fun managedImport(): File {
            val directory = File(context.cacheDir, "file_dialog-${UUID.randomUUID()}")
            assertTrue(directory.mkdir())
            return File(directory, "selected.bin").apply { writeText("sensitive") }
        }

        val delivered = managedImport()
        val discarded = managedImport()
        val outside = File(context.cacheDir, "not-managed-${UUID.randomUUID()}.bin")
            .apply { writeText("keep") }
        try {
            val deliveredLatch = CountDownLatch(1)
            val deliveredResult = object : MethodChannel.Result {
                override fun success(result: Any?) = deliveredLatch.countDown()
                override fun error(code: String, message: String?, details: Any?) =
                    throw AssertionError("unexpected delivered error")
                override fun notImplemented() = throw AssertionError("unexpected missing method")
            }
            val deliveredCompletion = MainThreadResult(deliveredResult)
            Thread {
                deliveredCompletion.success(
                    delivered.path,
                    discardCleanup = {
                        DocumentIoBridge.deleteManagedImport(context.cacheDir, delivered.path)
                    },
                )
            }.start()
            assertTrue(deliveredLatch.await(3, TimeUnit.SECONDS))
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            assertTrue(delivered.exists())

            val closedLatch = CountDownLatch(1)
            val discardCleanupLatch = CountDownLatch(1)
            val callbackCount = AtomicInteger(0)
            val discardedResult = object : MethodChannel.Result {
                override fun success(result: Any?) {
                    callbackCount.incrementAndGet()
                }
                override fun error(code: String, message: String?, details: Any?) {
                    callbackCount.incrementAndGet()
                    closedLatch.countDown()
                }
                override fun notImplemented() = throw AssertionError("unexpected missing method")
            }
            val discardedCompletion = MainThreadResult(discardedResult)
            discardedCompletion.error("DOCUMENT_IO_CANCELLED", "Activity closed")
            assertTrue(closedLatch.await(3, TimeUnit.SECONDS))
            Thread {
                discardedCompletion.success(
                    discarded.path,
                    discardCleanup = {
                        DocumentIoBridge.deleteManagedImport(context.cacheDir, discarded.path)
                        discardCleanupLatch.countDown()
                    },
                )
            }.start()
            assertTrue(discardCleanupLatch.await(3, TimeUnit.SECONDS))
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            assertEquals(1, callbackCount.get())
            assertFalse(discarded.exists())
            assertFalse(discarded.parentFile!!.exists())

            DocumentIoBridge.deleteManagedImport(context.cacheDir, outside.path)
            assertTrue(outside.exists())
        } finally {
            delivered.delete()
            delivered.parentFile?.delete()
            discarded.delete()
            discarded.parentFile?.delete()
            outside.delete()
        }
    }

    @Test
    fun processMemoryUsesAValidKernelPageSize() {
        assertTrue(ProcessMemory.pageSizeBytes() > 0)
        assertTrue(ProcessMemory.rssMb(android.os.Process.myPid()) > 0.0)
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

    @Test
    fun staleRuntimeConfigIsDeletedWhenServiceIsCreated() {
        FrpcService.stop(context)
        waitUntil { FrpcService.instance == null }
        val runtimeConfig = FrpcService.runtimeConfigFile(context)
        runtimeConfig.writeText("token = stale-secret")
        assertTrue(runtimeConfig.exists())

        val intent = Intent(context, FrpcService::class.java)
            .setAction("com.frp.frp_app.test.INVALID")
        if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
        else context.startService(intent)

        assertTrue(waitUntil { !runtimeConfig.exists() })
        assertTrue(waitUntil { FrpcService.instance == null })
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
