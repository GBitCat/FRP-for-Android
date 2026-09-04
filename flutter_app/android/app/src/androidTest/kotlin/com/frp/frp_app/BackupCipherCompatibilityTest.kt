package com.frp.frp_app

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BackupCipherCompatibilityTest {
    @Test
    fun decryptsGoPortableBackupNonAsciiKnownVectors() {
        val expected = "FRPB cross-language vector: 设备证书".toByteArray(Charsets.UTF_8)
        val vectors = listOf(
            1 to (
                "RlJQQgEBAAGGoBAMMDEyMzQ1Njc4OWFiY2RlZmFiY2RlZmdoaWprbIoZ+Wwmla8A7f1r" +
                    "abOqIPmvYUGj5sWvvpN3Bh2pHS9L0GibksGlpQCDsZGa0zMjXobiizAfCd8r"
            ),
            2 to (
                "RlJQQgECAAGGoBAMMDEyMzQ1Njc4OWFiY2RlZmFiY2RlZmdoaWprbOgJzfRPHZWAu7BJ" +
                    "pHlSEUghVoWWNh83Sz2JZW9g581gZP74VKJVRGao2oAEtrbJkfQ9KLeJnNZ6"
            ),
        )

        vectors.forEach { (kdf, encoded) ->
            val envelope = Base64.decode(encoded, Base64.NO_WRAP)
            assertEquals(kdf, envelope[5].toInt())
            assertArrayEquals(
                expected,
                BackupCipher.decrypt(envelope, "备份密码🔐portable"),
            )
        }
    }
}
