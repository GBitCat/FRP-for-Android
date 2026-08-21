package com.frp.frp_app

import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Arrays
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/** Portable password-encrypted backup envelope (PBKDF2 + AES-256-GCM). */
object BackupCipher {
    private val MAGIC = byteArrayOf('F'.code.toByte(), 'R'.code.toByte(), 'P'.code.toByte(), 'B'.code.toByte())
    private const val VERSION: Byte = 1
    private const val KDF_SHA256: Byte = 1
    private const val KDF_SHA1: Byte = 2
    private const val ITERATIONS = 600_000
    private const val SALT_SIZE = 16
    private const val IV_SIZE = 12
    private const val KEY_BITS = 256
    private const val MAX_PLAINTEXT_BYTES = 5 * 1024 * 1024

    fun encrypt(plainText: ByteArray, password: String): ByteArray {
        require(plainText.isNotEmpty() && plainText.size <= MAX_PLAINTEXT_BYTES) {
            "Backup payload size is invalid"
        }
        require(password.length >= 12) { "Backup password must contain at least 12 characters" }
        val salt = ByteArray(SALT_SIZE).also(SecureRandom()::nextBytes)
        val iv = ByteArray(IV_SIZE).also(SecureRandom()::nextBytes)
        val kdf = preferredKdf()
        val header = header(kdf, ITERATIONS, salt, iv)
        val key = deriveKey(password, salt, ITERATIONS, kdf)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
            cipher.updateAAD(header)
            header + cipher.doFinal(plainText)
        } finally {
            Arrays.fill(key, 0)
        }
    }

    fun decrypt(envelope: ByteArray, password: String): ByteArray {
        require(envelope.size > 28 && envelope.size <= MAX_PLAINTEXT_BYTES + 128) {
            "Encrypted backup size is invalid"
        }
        val buffer = ByteBuffer.wrap(envelope)
        val magic = ByteArray(MAGIC.size).also(buffer::get)
        require(magic.contentEquals(MAGIC)) { "Not an FRP encrypted backup" }
        require(buffer.get() == VERSION) { "Unsupported backup version" }
        val kdf = buffer.get()
        require(kdf == KDF_SHA256 || kdf == KDF_SHA1) { "Unsupported backup KDF" }
        val iterations = buffer.int
        require(iterations in 100_000..1_000_000) { "Invalid backup KDF cost" }
        val saltSize = buffer.get().toInt() and 0xff
        val ivSize = buffer.get().toInt() and 0xff
        require(saltSize in 16..32 && ivSize in 12..16 && buffer.remaining() > saltSize + ivSize + 16) {
            "Invalid encrypted backup header"
        }
        val salt = ByteArray(saltSize).also(buffer::get)
        val iv = ByteArray(ivSize).also(buffer::get)
        val headerSize = buffer.position()
        val cipherText = ByteArray(buffer.remaining()).also(buffer::get)
        val key = deriveKey(password, salt, iterations, kdf)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
            cipher.updateAAD(envelope.copyOfRange(0, headerSize))
            cipher.doFinal(cipherText)
        } catch (_: AEADBadTagException) {
            throw IllegalArgumentException("Wrong password or damaged backup")
        } finally {
            Arrays.fill(key, 0)
        }
    }

    private fun preferredKdf(): Byte = try {
        SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        KDF_SHA256
    } catch (_: Exception) {
        KDF_SHA1
    }

    private fun deriveKey(
        password: String,
        salt: ByteArray,
        iterations: Int,
        kdf: Byte,
    ): ByteArray {
        val chars = password.toCharArray()
        return try {
            val algorithm = if (kdf == KDF_SHA256) "PBKDF2WithHmacSHA256" else "PBKDF2WithHmacSHA1"
            SecretKeyFactory.getInstance(algorithm)
                .generateSecret(PBEKeySpec(chars, salt, iterations, KEY_BITS))
                .encoded
        } finally {
            Arrays.fill(chars, '\u0000')
        }
    }

    private fun header(kdf: Byte, iterations: Int, salt: ByteArray, iv: ByteArray): ByteArray =
        ByteBuffer.allocate(MAGIC.size + 1 + 1 + 4 + 1 + 1 + salt.size + iv.size)
            .put(MAGIC)
            .put(VERSION)
            .put(kdf)
            .putInt(iterations)
            .put(salt.size.toByte())
            .put(iv.size.toByte())
            .put(salt)
            .put(iv)
            .array()
}
