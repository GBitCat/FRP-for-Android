package com.frp.frp_app

import java.io.DataInputStream
import java.io.IOException
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** A new key is shared only with this service's child frpc for each launch. */
internal class FrpcEndpointAuth(private val key: ByteArray = ByteArray(32).also(random::nextBytes)) {
    init { require(key.size == 32) }

    companion object {
        private val random = SecureRandom()
    }

    fun start(builder: ProcessBuilder, rules: List<Socks5ForwardRule>): Process {
        val ports = rules.flatMap { it.upstreams }.map { it.port }.distinct()
        builder.environment()["FRPC_ANDROID_ENDPOINT_PORTS"] = ports.joinToString(",")
        val child = builder.start()
        try {
            // frp's TOML templates can access the startup environment. Only
            // this private pipe carries the proof key used by the child.
            child.outputStream.use { it.write(key) }
            return child
        } catch (failure: IOException) {
            child.destroy()
            throw failure
        }
    }

    /** Returns frpc's SOCKS UDP frame limit, including the target address header. */
    fun verify(socket: Socket, visitor: String, input: DataInputStream): Int {
        val nonce = ByteArray(32).also(random::nextBytes)
        val output = socket.getOutputStream()
        output.write(nonce)
        val limit = input.readUnsignedShort()
        val serverNonce = ByteArray(32).also(input::readFully)
        val serverProof = ByteArray(32).also(input::readFully)
        val fields = ByteBuffer.allocate(6)
            .putShort(socket.localPort.toShort()).putShort(socket.port.toShort())
            .putShort(limit.toShort()).array()
        fun proof(role: String): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(key, "HmacSHA256"))
            mac.update("frpc-android-endpoint-v1/$role".toByteArray(Charsets.US_ASCII))
            mac.update(fields)
            mac.update(nonce)
            mac.update(serverNonce)
            return mac.doFinal(visitor.toByteArray(Charsets.UTF_8))
        }
        if (!MessageDigest.isEqual(serverProof, proof("server"))) {
            throw IOException("Local frpc endpoint could not be verified")
        }
        output.write(proof("client"))
        return limit
    }
}
