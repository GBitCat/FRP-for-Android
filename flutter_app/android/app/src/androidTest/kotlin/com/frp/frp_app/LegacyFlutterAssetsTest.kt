package com.frp.frp_app

import android.content.Context
import android.system.Os
import android.system.OsConstants
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LegacyFlutterAssetsTest {
    @get:Rule
    val temp = TemporaryFolder(ApplicationProvider.getApplicationContext<Context>().cacheDir)

    @Test
    fun removesOnlyTheTwoLegacyFilesAndHandlesMissingAssets() {
        val root = File(temp.root, "app_flutter")
        assertTrue(LegacyFlutterAssets.clean(root))
        assertFalse(root.exists())
        val assets = File(root, "flutter_assets")
        assertTrue(assets.mkdirs())
        val kernel = File(assets, "kernel_blob.bin").apply { writeText("kernel") }
        val isolate = File(assets, "isolate_snapshot_data").apply { writeText("isolate") }
        val retained = listOf(
            File(assets, "vm_snapshot_data"),
            File(assets, "kernel_blob.bin.backup"),
            File(assets, "nested/kernel_blob.bin"),
            File(root, "res_timestamp-14-123"),
            File(temp.root, "shared_prefs/config.xml"),
            File(temp.root, "no_backup/tls/key"),
        )
        retained.forEach {
            it.parentFile!!.mkdirs()
            it.writeText("preserve")
        }

        assertTrue(LegacyFlutterAssets.clean(root))
        assertFalse(kernel.exists())
        assertFalse(isolate.exists())
        assertTrue(LegacyFlutterAssets.clean(root))
        retained.forEach { assertEquals("preserve", it.readText()) }
    }

    @Test
    fun skipsSymbolicLinksAndDirectoriesNamedLikeSnapshots() {
        val root = temp.newFolder("app_flutter")
        val assets = File(root, "flutter_assets").apply { mkdir() }
        val outside = temp.newFile("user-data").apply { writeText("keep") }
        val leafLink = File(assets, "kernel_blob.bin")
        Os.symlink(outside.path, leafLink.path)
        val namedDirectory = File(assets, "isolate_snapshot_data").apply { mkdir() }

        LegacyFlutterAssets.clean(root)
        assertEquals(outside.path, Os.readlink(leafLink.path))
        assertEquals("keep", outside.readText())
        assertTrue(namedDirectory.isDirectory)

        val otherRoot = temp.newFolder("other")
        val linkedAssets = File(otherRoot, "flutter_assets")
        Os.symlink(assets.path, linkedAssets.path)
        val linkedRoot = File(temp.root, "app_flutter_link")
        Os.symlink(root.path, linkedRoot.path)
        Os.remove(leafLink.path)
        leafLink.writeText("must remain")
        LegacyFlutterAssets.clean(otherRoot)
        LegacyFlutterAssets.clean(linkedRoot)
        assertEquals("must remain", leafLink.readText())
        assertEquals(assets.path, Os.readlink(linkedAssets.path))
        assertEquals(root.path, Os.readlink(linkedRoot.path))
    }

    @Test
    fun failedUnlinkCanBeRetried() {
        val root = temp.newFolder("app_flutter")
        val assets = File(root, "flutter_assets").apply { mkdir() }
        val kernel = File(assets, "kernel_blob.bin").apply { writeText("kernel") }
        Os.chmod(assets.path, OsConstants.S_IRUSR or OsConstants.S_IXUSR)
        try {
            assertFalse(LegacyFlutterAssets.clean(root))
            assertTrue(kernel.exists())
        } finally {
            Os.chmod(assets.path, OsConstants.S_IRWXU)
        }
        assertTrue(LegacyFlutterAssets.clean(root))
        assertFalse(kernel.exists())
    }
}
