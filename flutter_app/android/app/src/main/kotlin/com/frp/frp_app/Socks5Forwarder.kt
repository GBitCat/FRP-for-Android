package com.frp.frp_app

import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** Local fixed-port adapters. Only the frpc SOCKS endpoint receives credentials. */
internal data class Socks5Upstream(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
) {
    fun toJson() = JSONObject().put("id", id).put("name", name).put("host", host)
        .put("port", port).put("username", username).put("password", password)
}

internal data class Socks5ForwardRule @JvmOverloads constructor(
    val protocol: String,
    val bindAddress: String,
    val listenPort: Int,
    val targetIp: String,
    val targetPort: Int,
    val upstreams: List<Socks5Upstream>,
    val mode: String = "onDemand",
    val logContext: Socks5LogContext? = null,
) {
    fun toJson() = JSONObject().put("protocol", protocol).put("bindAddress", bindAddress)
        .put("listenPort", listenPort).put("targetIp", targetIp).put("targetPort", targetPort).put("mode", mode)
        .put("upstreams", JSONArray().also { array -> upstreams.forEach { array.put(it.toJson()) } })
        .also { result -> logContext?.let { result.put("logContext", it.toJson()) } }

    companion object {
        const val MAX_LISTENERS = 256
        const val MAX_UPSTREAMS = 128

        fun fromMaps(input: List<*>): List<Socks5ForwardRule> {
            require(input.size <= MAX_LISTENERS) { "Too many SOCKS5 listeners" }
            return input.map { value ->
                require(value is Map<*, *>) { "Invalid SOCKS5 listener" }
                fromJson(JSONObject(value))
            }.also(::validateListeners)
        }

        fun fromJsonArray(input: JSONArray): List<Socks5ForwardRule> {
            require(input.length() <= MAX_LISTENERS) { "Too many SOCKS5 listeners" }
            return (0 until input.length()).map { fromJson(input.getJSONObject(it)) }
                .also(::validateListeners)
        }

        private fun fromJson(input: JSONObject): Socks5ForwardRule {
            val protocol = string(input, "protocol")
            require(protocol == "tcp" || protocol == "udp") { "Invalid SOCKS5 transport" }
            val bindAddress = string(input, "bindAddress")
            numericAddress(bindAddress)
            val targetIp = string(input, "targetIp")
            numericAddress(targetIp)
            val mode = if (input.has("mode")) string(input, "mode") else "onDemand"
            require(mode == "onDemand" || mode == "immediate") { "Invalid SOCKS5 connection mode" }
            val upstreams = input.getJSONArray("upstreams")
            require(upstreams.length() in 1..MAX_UPSTREAMS) { "Invalid SOCKS5 upstream count" }
            return Socks5ForwardRule(
                protocol, bindAddress, port(input, "listenPort"), targetIp, port(input, "targetPort"),
                (0 until upstreams.length()).map { index ->
                    val upstream = upstreams.getJSONObject(index)
                    val host = string(upstream, "host")
                    require(numericAddress(host).isLoopbackAddress) { "SOCKS5 upstream must be local" }
                    val username = string(upstream, "username")
                    val password = string(upstream, "password")
                    require(username.toByteArray(Charsets.UTF_8).size <= 255 &&
                        password.toByteArray(Charsets.UTF_8).size <= 255) { "SOCKS5 credentials are too long" }
                    Socks5Upstream(string(upstream, "id"), string(upstream, "name"), host,
                        port(upstream, "port"), username, password)
                },
                mode,
                if (input.has("logContext")) Socks5LogContext.fromJson(input.get("logContext")) else null,
            )
        }

        private fun string(input: JSONObject, key: String): String {
            val value = input.get(key)
            require(value is String && value.length <= 4096) { "Invalid SOCKS5 field" }
            return value
        }

        private fun port(input: JSONObject, key: String): Int {
            val value = input.get(key)
            require(value is Number && value.toDouble() == value.toInt().toDouble() &&
                value.toInt() in 1..65535) { "Invalid SOCKS5 port" }
            return value.toInt()
        }

        private fun validateListeners(rules: List<Socks5ForwardRule>) {
            val occupied = mutableSetOf<String>()
            rules.forEach { rule ->
                val ip = numericAddress(rule.bindAddress)
                require(occupied.add("${rule.protocol}/${ip.hostAddress}/${rule.listenPort}")) {
                    "Duplicate SOCKS5 listener"
                }
            }
        }
    }
}

/** Encrypted as one value by FrpcService; no SOCKS credentials enter frpc's TOML. */
internal data class FrpcRuntimePayload(
    val configContent: String,
    val forwards: List<Socks5ForwardRule> = emptyList(),
) {
    fun encode(): String {
        if (forwards.isEmpty()) return configContent
        return JSONObject().put("androidRuntimeVersion", 1).put("configContent", configContent)
            .put("socks5Forwards", JSONArray().also { array -> forwards.forEach { array.put(it.toJson()) } })
            .toString()
    }

    companion object {
        fun decode(value: String): FrpcRuntimePayload {
            if (!value.trimStart().startsWith("{")) return FrpcRuntimePayload(value)
            val input = JSONObject(value)
            require(input.get("androidRuntimeVersion") == 1) { "Unsupported runtime configuration" }
            return FrpcRuntimePayload(input.getString("configContent"),
                Socks5ForwardRule.fromJsonArray(input.getJSONArray("socks5Forwards")))
        }
    }
}

private fun numericAddress(value: String): InetAddress {
    require(value.isNotEmpty() && value.length <= 45 &&
        value.all { it in "0123456789abcdefABCDEF:." } &&
        (':' in value || value.count { it == '.' } == 3)) { "An IP address is required" }
    return InetAddress.getByName(value)
}

internal class Socks5ListenException(rule: Socks5ForwardRule?) : IOException(
    if (rule == null) "Unable to start SOCKS5 forwarding listeners"
    else "Unable to listen on ${rule.protocol.uppercase()} ${rule.bindAddress}:${rule.listenPort}",
)

/**
 * One selector owns listener I/O and established UDP associations. TCP streams
 * use bounded workers; closing the service closes every pending and active socket.
 */
internal class Socks5Forwarder(
    private val rules: List<Socks5ForwardRule>,
    private val report: (String) -> Unit = {},
    private val handshakeTimeoutMs: Int = 75_000,
    private val udpIdleTimeoutMs: Long = 120_000,
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val selector = Selector.open()
    private val channels = ConcurrentHashMap<Closeable, Boolean>()
    private val sessions = ConcurrentHashMap<Session, Boolean>()
    private val permits = Semaphore(MAX_SESSIONS)
    private val actions = ConcurrentLinkedQueue<() -> Unit>()
    private val workerSequence = AtomicInteger()
    private val workers = ThreadPoolExecutor(0, MAX_SESSIONS * 2, 30, TimeUnit.SECONDS,
        SynchronousQueue(), { task -> Thread(task, "socks5-io-${workerSequence.incrementAndGet()}").apply { isDaemon = true } })
    private val started = AtomicBoolean(false)
    @Volatile private var listeners: List<Listener> = emptyList()
    @Volatile private var eventThread: Thread? = null
    private var nextTrafficMaintenanceAt = 0L
    private var trafficCursor = 0
    // Warm channels have their own capacity and workers, so a missing upstream
    // cannot occupy any worker/session needed by an actual application request.
    private val warmPermits = Semaphore(MAX_WARM_CHANNELS)
    private val warmHandshakes = Semaphore(MAX_WARM_HANDSHAKES)
    private val warmWorkers = ThreadPoolExecutor(MAX_WARM_HANDSHAKES, MAX_WARM_HANDSHAKES, 30, TimeUnit.SECONDS,
        ArrayBlockingQueue(MAX_WARM_HANDSHAKES), { task -> Thread(task, "socks5-warm-${workerSequence.incrementAndGet()}").apply { isDaemon = true } })
        .apply { allowCoreThreadTimeOut(true) }
    @Volatile private var warmSlots: List<WarmSlot> = emptyList() // published once before eventLoop starts
    private var warmCursor = 0
    private var nextWarmMaintenanceAt = 0L

    private inner class Listener(val rule: Socks5ForwardRule, val channel: Closeable) {
        val traffic = Socks5TrafficStats()
        val lastFailureReportMs = AtomicLong(0)
        var lastTrafficRevision = 0L // traffic logging monitor owned
        var lastTrafficAt = now()
        val sequence = AtomicInteger()
        val udpSessions = ConcurrentHashMap<InetSocketAddress, UdpSession>()
        val warm = if (rule.mode == "immediate") rule.upstreams.mapIndexed { index, upstream ->
            WarmSlot(this, upstream, index + 1)
        } else emptyList()
        val connectionAnnounced = AtomicBoolean(false)
        val readyAnnounced = AtomicBoolean(false)
        fun orderedUpstreams(): List<Socks5Upstream> {
            val start = Math.floorMod(sequence.getAndIncrement(), rule.upstreams.size)
            return rule.upstreams.indices.map { rule.upstreams[(start + it) % rule.upstreams.size] }
        }
    }

    private open inner class Resources : Closeable {
        val ended = AtomicBoolean(false)
        private val resources = ConcurrentHashMap<Closeable, Boolean>()

        fun <T : Closeable> track(resource: T): T {
            resources[resource] = true
            if (ended.get() || closed.get()) {
                release(resource)
                throw IOException("SOCKS5 forwarding stopped")
            }
            return resource
        }

        fun release(resource: Closeable) {
            resources.remove(resource)
            runCatching { resource.close() }
        }

        fun transferTo(destination: Resources) {
            if (ended.get() || closed.get()) throw IOException("SOCKS5 forwarding stopped")
            for (resource in resources.keys) {
                destination.track(resource)
                resources.remove(resource)
            }
        }

        override fun close() {
            if (!ended.compareAndSet(false, true)) return
            resources.keys.forEach(::release)
            runCatching { selector.wakeup() }
        }
    }

    private abstract inner class Session : Resources() {
        val lastActivity = AtomicLong(now())
        val blockedWriteA = AtomicLong(0)
        val blockedWriteB = AtomicLong(0)
        val negotiationDeadline = AtomicLong(0)
        private val removed = AtomicBoolean(false)

        override fun close() {
            super.close()
            if (removed.compareAndSet(false, true)) {
                sessions.remove(this)
                permits.release()
            }
        }
    }

    private inner class Transport(val control: SocketChannel, val datagrams: DatagramChannel? = null) {
        fun release(owner: Resources) {
            owner.release(control)
            datagrams?.let(owner::release)
        }
    }

    private inner class Prepared : Resources() {
        val deadline = now() + handshakeTimeoutMs
        var readyAt = 0L
        var transport: Transport? = null
    }

    private inner class WarmSlot(val listener: Listener, val upstream: Socks5Upstream, val number: Int) {
        private var pending: Prepared? = null
        private var ready: Prepared? = null
        private var nextAttempt = 0L
        private var failures = 0
        private var announced = false
        private var readyAnnounced = false
        private var lastFailureLog = 0L
        private val label get() = "${listener.rule.protocol.uppercase()} ${listener.rule.listenPort} upstream $number"

        @Synchronized
        fun begin(time: Long): Prepared? {
            if (closed.get() || pending != null || ready != null || time < nextAttempt || !warmPermits.tryAcquire()) return null
            val result = Prepared()
            pending = result
            if (!announced) { announced = true; log(listener.rule, "warm_start", "$label: preparing immediate channel") }
            return result
        }

        @Synchronized
        fun publish(value: Prepared) {
            if (pending !== value || closed.get()) { value.close(); return }
            pending = null
            ready = value
            value.readyAt = now()
            failures = 0
            if (!readyAnnounced) { readyAnnounced = true; log(listener.rule, "warm_ready", "$label: immediate channel ready") }
        }

        @Synchronized
        fun cancelPreparation(value: Prepared) {
            if (pending === value) {
                pending = null
                warmPermits.release()
                nextAttempt = now() + WARM_MAINTENANCE_MS
            }
            value.close()
        }

        @Synchronized
        fun failed(value: Prepared) {
            if (pending !== value && ready !== value) { value.close(); return }
            if (pending === value) pending = null
            if (ready === value) ready = null
            value.close()
            warmPermits.release()
            if (closed.get()) return
            failures = (failures + 1).coerceAtMost(6)
            val retryMs = (1_000L shl (failures - 1)).coerceAtMost(30_000L)
            nextAttempt = now() + retryMs
            readyAnnounced = false
            if (lastFailureLog == 0L || now() - lastFailureLog >= 30_000) {
                lastFailureLog = now()
                log(listener.rule, "warm_retry", "$label: channel unavailable; retrying in ${retryMs / 1_000}s",
                    JSONObject().put("retryMs", retryMs).put("upstreamNumber", number))
            }
        }

        private fun healthy(value: Prepared): Boolean = try {
            // No more SOCKS control bytes are legal before a TCP CONNECT or
            // after UDP ASSOCIATE. A nonblocking read detects EOF without
            // reserving a reader thread or consuming application data.
            value.transport!!.control.read(ByteBuffer.allocate(1)) == 0
        } catch (_: Exception) { false }

        @Synchronized
        fun maintain(time: Long) {
            pending?.let { if (time >= it.deadline) failed(it) }
            ready?.let {
                if (!healthy(it)) failed(it)
                else if (warmSlots.size > MAX_WARM_CHANNELS && time - it.readyAt >= WARM_ROTATION_MS) {
                    ready = null
                    it.close()
                    warmPermits.release()
                    nextAttempt = time + 1_000
                }
            }
        }

        @Synchronized
        fun take(owner: Resources): Transport? {
            val value = ready ?: return null
            if (!healthy(value)) { failed(value); return null }
            ready = null
            warmPermits.release()
            try {
                val transport = value.transport!!
                transport.control.configureBlocking(true)
                value.transferTo(owner)
                value.close()
                return transport
            } catch (error: Exception) {
                value.close()
                throw error
            }
        }

        @Synchronized
        fun close() {
            pending?.let { it.close(); warmPermits.release() }
            ready?.let { it.close(); warmPermits.release() }
            pending = null
            ready = null
        }
    }

    private inner class TcpSession(val listener: Listener, val client: Socket) : Session() {
        init { track(client) }
        fun run() {
            try {
                val upstream = openChannel(this, listener).control.socket()
                val completed = AtomicInteger()
                val copyA = {
                    copyHalf(client, upstream, blockedWriteA, true)
                    if (completed.incrementAndGet() == 2) close()
                }
                val copyB = {
                    copyHalf(upstream, client, blockedWriteB, false)
                    if (completed.incrementAndGet() == 2) close()
                }
                workers.execute(copyB)
                copyA()
            } catch (_: Exception) {
                if (!closed.get() && !ended.get()) warn(listener, "connect_failed", "unable to connect or authenticate")
                close()
            }
        }

        private fun copyHalf(source: Socket, target: Socket, blocked: AtomicLong, toFrpc: Boolean) {
            val buffer = ByteBuffer.allocate(16 * 1024)
            try {
                // SocketAdaptor streams can share a blocking-mode lock on
                // Android. Keep the established tunnel on the channels so a
                // pending read never serializes the opposite-direction write.
                val input = source.channel ?: throw IOException("Missing TCP source channel")
                val output = target.channel ?: throw IOException("Missing TCP target channel")
                while (!ended.get() && !closed.get()) {
                    buffer.clear()
                    val count = input.read(buffer)
                    if (count < 0) {
                        runCatching { output.shutdownOutput() }
                        return
                    }
                    if (count == 0) continue
                    buffer.flip()
                    blocked.set(now())
                    try {
                        while (buffer.hasRemaining() && !ended.get() && !closed.get()) {
                            val written = output.write(buffer)
                            if (written > 0) listener.traffic.tcpSubmitted(toFrpc, written)
                        }
                    } finally { blocked.set(0) }
                    lastActivity.set(now())
                }
            } catch (_: Exception) {
                if (!closed.get() && !ended.get()) warn(listener, "stream_failed", "TCP stream closed after an I/O failure")
                close()
            } finally {
                buffer.array().fill(0)
            }
        }
    }

    private inner class UdpSession(val listener: Listener, val source: InetSocketAddress) : Session() {
        // Closing can originate in a handshake worker. Synchronize queue
        // ownership so every discarded cached datagram is counted exactly once.
        private val pending = ArrayDeque<ByteArray>()
        private var pendingBytes = 0
        private var relay: DatagramChannel? = null
        private val header = byteArrayOf(0, 0, 0) + encodeAddress(
            numericAddress(listener.rule.targetIp), listener.rule.targetPort)
        @Volatile private var ready = false

        @Synchronized fun offer(payload: ByteArray) {
            if (ended.get()) { listener.traffic.drop(Socks5Drop.SESSION_CLOSED, payload.size); return }
            lastActivity.set(now())
            if (payload.size + header.size > MAX_DATAGRAM) {
                listener.traffic.drop(Socks5Drop.OVERSIZE, payload.size); return
            }
            if (!ready) {
                if (pending.size < 16 && pendingBytes + payload.size <= 256 * 1024) {
                    pending.addLast(payload)
                    pendingBytes += payload.size
                } else listener.traffic.drop(Socks5Drop.PENDING_FULL, payload.size)
                return
            }
            val packet = ByteBuffer.allocate(header.size + payload.size).put(header).put(payload)
            packet.flip()
            try {
                val written = relay?.write(packet) ?: 0
                when (written) {
                    header.size + payload.size -> listener.traffic.udpFrpcSubmitted(written, payload.size)
                    0 -> listener.traffic.drop(Socks5Drop.WRITE_ZERO, payload.size)
                    else -> listener.traffic.drop(Socks5Drop.WRITE_PARTIAL, payload.size)
                }
            } catch (_: Exception) {
                listener.traffic.drop(Socks5Drop.WRITE_ERROR, payload.size)
                if (!closed.get() && !ended.get()) warn(listener, "udp_write_failed", "unable to submit UDP datagram to local frpc")
                close()
            }
        }

        fun establish() {
            try {
                // Immediate mode consumes a completed, source-independent
                // ASSOCIATE. Each local source still owns a distinct control
                // connection/UDP relay, exactly as on-demand sessions do.
                val transport = openChannel(this, listener)
                val datagrams = transport.datagrams ?: throw IOException("Missing SOCKS5 UDP relay")
                val controlChannel = transport.control
                enqueue {
                    synchronized(this) {
                        if (ended.get()) return@enqueue
                        try {
                            datagrams.configureBlocking(false)
                            controlChannel.configureBlocking(false)
                            datagrams.register(selector, SelectionKey.OP_READ, UdpRelay(this))
                            controlChannel.register(selector, SelectionKey.OP_READ, UdpControl(this))
                            relay = datagrams
                            ready = true
                            while (pending.isNotEmpty()) {
                                val payload = pending.removeFirst()
                                pendingBytes -= payload.size
                                offer(payload)
                            }
                        } catch (_: Exception) { close() }
                    }
                }
            } catch (_: Exception) {
                if (!closed.get() && !ended.get()) warn(listener, "connect_failed", "unable to connect or authenticate")
                close()
            }
        }

        fun receive(packet: ByteBuffer) {
            val frameBytes = packet.remaining()
            listener.traffic.udpFrpcReceived(frameBytes)
            try {
                if (packet.remaining() < 4 || packet.get().toInt() != 0 || packet.get().toInt() != 0) {
                    listener.traffic.drop(Socks5Drop.MALFORMED, frameBytes); return
                }
                if (packet.get().toInt() != 0) {
                    listener.traffic.drop(Socks5Drop.FRAGMENTED, frameBytes); return
                }
                skipDatagramAddress(packet)
            } catch (_: Exception) {
                listener.traffic.drop(Socks5Drop.MALFORMED, frameBytes); return
            }
            val payloadBytes = packet.remaining()
            listener.traffic.udpFrpcPayload(payloadBytes)
            try {
                val written = (listener.channel as DatagramChannel).send(packet, source)
                when (written) {
                    payloadBytes -> listener.traffic.udpLocalSubmitted(written)
                    0 -> listener.traffic.drop(Socks5Drop.WRITE_ZERO, payloadBytes)
                    else -> listener.traffic.drop(Socks5Drop.WRITE_PARTIAL, payloadBytes)
                }
                lastActivity.set(now())
            } catch (_: Exception) {
                listener.traffic.drop(Socks5Drop.WRITE_ERROR, payloadBytes)
                if (!closed.get() && !ended.get()) warn(listener, "udp_write_failed", "unable to return UDP datagram to local app")
            }
        }

        @Synchronized override fun close() {
            if (pending.isNotEmpty()) {
                listener.traffic.drop(Socks5Drop.SESSION_CLOSED, pendingBytes, pending.size)
                pending.clear()
                pendingBytes = 0
            }
            super.close()
            listener.udpSessions.remove(source, this)
        }
    }

    private inner class UdpRelay(val session: UdpSession)
    private inner class UdpControl(val session: UdpSession)

    /** Bind all ports before advertising success. No partial listener set survives failure. */
    fun start() {
        check(started.compareAndSet(false, true)) { "SOCKS5 forwarder already started" }
        var binding: Socks5ForwardRule? = null
        val listeners = mutableListOf<Listener>()
        try {
            for (rule in rules) {
                binding = rule
                check(!closed.get())
                val address = InetSocketAddress(numericAddress(rule.bindAddress), rule.listenPort)
                if (rule.protocol == "tcp") {
                    val channel = ServerSocketChannel.open()
                    channels[channel] = true
                    if (closed.get()) { channel.close(); throw IOException("SOCKS5 forwarding stopped") }
                    channel.socket().reuseAddress = true
                    channel.bind(address)
                    channel.configureBlocking(false)
                    val listener = Listener(rule, channel)
                    listeners.add(listener)
                    channel.register(selector, SelectionKey.OP_ACCEPT, listener)
                } else {
                    val channel = DatagramChannel.open()
                    channels[channel] = true
                    if (closed.get()) { channel.close(); throw IOException("SOCKS5 forwarding stopped") }
                    channel.socket().reuseAddress = false
                    channel.bind(address)
                    channel.configureBlocking(false)
                    val listener = Listener(rule, channel)
                    listeners.add(listener)
                    channel.register(selector, SelectionKey.OP_READ, listener)
                }
            }
            // Interleave listeners so one group with many upstreams cannot
            // occupy every warm slot before another listener gets a turn.
            val maxUpstreams = listeners.maxOfOrNull { it.warm.size } ?: 0
            val slots = mutableListOf<WarmSlot>()
            for (index in 0 until maxUpstreams) for (listener in listeners) {
                listener.warm.getOrNull(index)?.let(slots::add)
            }
            warmSlots = slots
            this.listeners = listeners.toList()
            for (listener in listeners) log(listener.rule, "listening", "listening (${listener.rule.mode})")
            eventThread = Thread(::eventLoop, "socks5-listeners").apply { isDaemon = true; start() }
        } catch (_: Exception) {
            binding?.let { log(it, "listen_failed", "unable to bind SOCKS5 listener") }
            close()
            throw Socks5ListenException(binding)
        }
    }

    private fun eventLoop() {
        val buffer = ByteBuffer.allocate(65_535)
        try {
            while (!closed.get()) {
                while (true) (actions.poll() ?: break).invoke()
                maintainWarmChannels()
                maintainTraffic()
                selector.select(WARM_MAINTENANCE_MS)
                val keys = selector.selectedKeys().iterator()
                while (keys.hasNext()) {
                    val key = keys.next()
                    keys.remove()
                    if (!key.isValid) continue
                    try {
                        when (val attachment = key.attachment()) {
                            is Listener -> {
                                if (key.isAcceptable) accept(attachment)
                                else {
                                    buffer.clear()
                                    val source = (key.channel() as DatagramChannel).receive(buffer) as? InetSocketAddress
                                    if (source != null) {
                                        buffer.flip()
                                        val payload = ByteArray(buffer.remaining())
                                        buffer.get(payload)
                                        receive(attachment, source, payload)
                                    }
                                }
                            }
                            is UdpRelay -> {
                                buffer.clear()
                                if ((key.channel() as DatagramChannel).receive(buffer) != null) {
                                    buffer.flip()
                                    attachment.session.receive(buffer)
                                }
                            }
                            is UdpControl -> {
                                buffer.clear()
                                if ((key.channel() as SocketChannel).read(buffer) < 0) {
                                    warn(attachment.session.listener, "udp_control_closed", "UDP association control closed")
                                    attachment.session.close()
                                }
                            }
                        }
                    } catch (_: Exception) {
                        when (val attachment = key.attachment()) {
                            is UdpRelay -> {
                                warn(attachment.session.listener, "udp_relay_failed", "UDP relay read failed")
                                attachment.session.close()
                            }
                            is UdpControl -> {
                                warn(attachment.session.listener, "udp_control_failed", "UDP association control read failed")
                                attachment.session.close()
                            }
                            is Listener -> if (!closed.get()) warn(attachment, "listener_failed", "listener I/O failed")
                        }
                    }
                }
                val time = now()
                sessions.keys.forEach { session ->
                    val negotiating = session.negotiationDeadline.get() > 0 && time >= session.negotiationDeadline.get()
                    val idle = session is UdpSession && time - session.lastActivity.get() > udpIdleTimeoutMs
                    val writeExpired = listOf(session.blockedWriteA.get(), session.blockedWriteB.get())
                        .any { it > 0 && time - it > WRITE_TIMEOUT_MS }
                    if (negotiating || idle || writeExpired) {
                        val listener = when (session) { is TcpSession -> session.listener; is UdpSession -> session.listener; else -> null }
                        if (listener != null && !idle) warn(listener, "session_timeout",
                            if (negotiating) "SOCKS5 negotiation timed out" else "TCP write timed out")
                        session.close()
                    }
                }
            }
        } catch (_: Exception) {
            if (!closed.get()) listeners.forEach { warn(it, "listeners_stopped", "SOCKS5 listeners stopped unexpectedly") }
        } finally { close() }
    }

    private fun accept(listener: Listener) {
        val channel = (listener.channel as ServerSocketChannel).accept() ?: return
        if (!permits.tryAcquire()) {
            warn(listener, "session_limit", "TCP connection rejected: session capacity reached")
            channel.close(); return
        }
        try {
            channel.configureBlocking(true)
            val session = TcpSession(listener, channel.socket())
            sessions[session] = true
            try { workers.execute(session::run) } catch (_: Exception) {
                warn(listener, "worker_rejected", "TCP connection rejected: worker unavailable")
                session.close()
            }
        } catch (_: Exception) {
            channel.close()
            permits.release()
        }
    }

    private fun receive(listener: Listener, source: InetSocketAddress, payload: ByteArray) {
        listener.traffic.udpLocalReceived(payload.size)
        var session = listener.udpSessions[source]
        if (session == null || session.ended.get()) {
            if (listener.udpSessions.size >= MAX_SESSIONS || !permits.tryAcquire()) {
                listener.traffic.drop(Socks5Drop.SESSION_LIMIT, payload.size)
                warn(listener, "session_limit", "UDP datagram rejected: session capacity reached")
                return
            }
            session = UdpSession(listener, source)
            sessions[session] = true
            listener.udpSessions[source] = session
            val created = session
            try { workers.execute(created::establish) } catch (_: Exception) {
                listener.traffic.drop(Socks5Drop.WORKER_REJECTED, payload.size)
                warn(listener, "worker_rejected", "UDP datagram rejected: worker unavailable")
                created.close(); return
            }
        }
        session.offer(payload)
    }

    private fun maintainWarmChannels() {
        if (warmSlots.isEmpty() || closed.get()) return
        val time = now()
        // Selector wakeups follow traffic volume. Pool health checks must not
        // become one nonblocking read per spare for every business datagram.
        if (time < nextWarmMaintenanceAt) return
        nextWarmMaintenanceAt = time + WARM_MAINTENANCE_MS
        warmSlots.forEach { it.maintain(time) }
        repeat(warmSlots.size) {
            if (closed.get() || !warmHandshakes.tryAcquire()) return
            val slot = warmSlots[warmCursor]
            warmCursor = (warmCursor + 1) % warmSlots.size
            val prepared = slot.begin(time)
            if (prepared == null) {
                warmHandshakes.release()
                return@repeat
            }
            try {
                warmWorkers.execute {
                    try {
                        val transport = establish(prepared, slot.listener, slot.upstream, prepared.deadline)
                        transport.control.configureBlocking(false)
                        prepared.transport = transport
                        slot.publish(prepared)
                    } catch (_: Exception) { slot.failed(prepared) }
                    finally {
                        warmHandshakes.release()
                        runCatching { selector.wakeup() }
                    }
                }
            } catch (_: Exception) {
                // Executor shutdown/capacity is not an upstream failure and
                // must not create false network warnings or retry backoff.
                slot.cancelPreparation(prepared)
                warmHandshakes.release()
            }
        }
    }

    private fun openChannel(session: Session, listener: Listener): Transport {
        val deadline = now() + handshakeTimeoutMs
        session.negotiationDeadline.set(deadline)
        if (listener.rule.mode == "onDemand" && listener.connectionAnnounced.compareAndSet(false, true)) {
            log(listener.rule, "connect_start", "first request, connecting")
        }
        for (upstream in listener.orderedUpstreams()) {
            if (session.ended.get() || closed.get()) throw IOException("SOCKS5 forwarding stopped")
            // A peer may close a warm TCP stream between its EOF check and
            // CONNECT. Retry the same upstream freshly before falling back.
            val slot = listener.warm.firstOrNull { it.upstream == upstream }
            var prepared = runCatching { slot?.take(session) }.getOrNull()
            for (attempt in 0 until (if (prepared == null) 1 else 2)) {
                var transport: Transport? = null
                try {
                    transport = prepared ?: establish(session, listener, upstream, deadline)
                    prepared = null
                    if (listener.rule.protocol == "tcp") {
                        request(transport.control.socket(), 1,
                            numericAddress(listener.rule.targetIp), listener.rule.targetPort, deadline)
                    }
                    session.negotiationDeadline.set(0)
                    if (listener.rule.mode == "onDemand" && listener.readyAnnounced.compareAndSet(false, true)) {
                        log(listener.rule, "channel_ready", "channel ready")
                    }
                    return transport
                } catch (_: Exception) {
                    transport?.release(session)
                    prepared = null
                    if (now() >= deadline || session.ended.get() || closed.get()) break
                }
            }
            if (now() >= deadline) break
        }
        throw IOException("No SOCKS5 upstream is available")
    }

    /** TCP stops after authentication. UDP must finish ASSOCIATE immediately;
     * the core's local handshake deadline must not expire while waiting for a
     * business datagram. Neither path connects to a TCP business target here. */
    private fun establish(owner: Resources, listener: Listener, upstream: Socks5Upstream, deadline: Long): Transport {
        val channel = owner.track(SocketChannel.open())
        var datagrams: DatagramChannel? = null
        try {
            val socket = channel.socket()
            socket.tcpNoDelay = true
            socket.keepAlive = true
            socket.connect(InetSocketAddress(numericAddress(upstream.host), upstream.port), remaining(deadline))
            socket.soTimeout = remaining(deadline)
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            val withAuth = upstream.username.isNotEmpty() || upstream.password.isNotEmpty()
            val method = if (withAuth) 2 else 0
            output.write(byteArrayOf(5, 1, method.toByte()))
            val greeting = readBytes(input, 2)
            if (greeting[0].toInt() != 5 || greeting[1].toInt() != method) throw IOException("SOCKS5 authentication unavailable")
            if (withAuth) {
                val username = upstream.username.toByteArray(Charsets.UTF_8)
                val password = upstream.password.toByteArray(Charsets.UTF_8)
                val credentials = byteArrayOf(1, username.size.toByte()) + username + byteArrayOf(password.size.toByte()) + password
                try { output.write(credentials) } finally { username.fill(0); password.fill(0); credentials.fill(0) }
                socket.soTimeout = remaining(deadline)
                val authenticated = readBytes(input, 2)
                if (authenticated[0].toInt() != 1 || authenticated[1].toInt() != 0) throw IOException("SOCKS5 authentication failed")
            }
            if (listener.rule.protocol == "udp") {
                datagrams = owner.track(DatagramChannel.open())
                datagrams.bind(InetSocketAddress("127.0.0.1", 0))
                val bound = datagrams.localAddress as InetSocketAddress
                val reply = request(socket, 3, bound.address, bound.port, deadline)
                val relayIp = reply.first ?: throw IOException("Invalid SOCKS5 UDP relay address")
                val endpoint = if (relayIp.isAnyLocalAddress) InetAddress.getByName("127.0.0.1") else relayIp
                require(endpoint.isLoopbackAddress && reply.second > 0) { "SOCKS5 relay must be local" }
                datagrams.connect(InetSocketAddress(endpoint, reply.second))
            }
            socket.soTimeout = 0
            return Transport(channel, datagrams)
        } catch (error: Exception) {
            owner.release(channel)
            datagrams?.let(owner::release)
            throw error
        }
    }

    private fun request(socket: Socket, command: Int, address: InetAddress, port: Int, deadline: Long): Pair<InetAddress?, Int> {
        socket.soTimeout = remaining(deadline)
        socket.getOutputStream().write(byteArrayOf(5, command.toByte(), 0) + encodeAddress(address, port))
        val input = socket.getInputStream()
        val response = readBytes(input, 3)
        if (response[0].toInt() != 5 || response[1].toInt() != 0 || response[2].toInt() != 0) {
            throw IOException("SOCKS5 connection was rejected")
        }
        val reply = readAddress(input)
        socket.soTimeout = 0
        return reply
    }

    private fun enqueue(action: () -> Unit) {
        if (closed.get()) return
        actions.add(action)
        selector.wakeup()
    }

    private fun log(rule: Socks5ForwardRule, event: String, message: String, extra: JSONObject? = null) {
        // Legacy payloads have no stable identity and remain global text lines.
        report(Socks5LogFormatter.line(rule, event, message, extra))
    }

    private fun warn(listener: Listener, event: String, message: String) {
        if (closed.get()) return
        val time = now()
        val previous = listener.lastFailureReportMs.get()
        if ((previous == 0L || time - previous >= 5_000) && listener.lastFailureReportMs.compareAndSet(previous, time)) {
            log(listener.rule, event, message)
        }
    }

    @Synchronized private fun maintainTraffic(forceFinal: Boolean = false) {
        if (listeners.isEmpty() || (!forceFinal && closed.get())) return
        val time = now()
        if (!forceFinal && time < nextTrafficMaintenanceAt) return
        nextTrafficMaintenanceAt = time + TRAFFIC_MAINTENANCE_MS
        var emitted = 0
        repeat(listeners.size) {
            val listener = listeners[trafficCursor]
            trafficCursor = (trafficCursor + 1) % listeners.size
            if (!forceFinal && time - listener.lastTrafficAt < TRAFFIC_INTERVAL_MS) return@repeat
            val snapshot = listener.traffic.snapshot(if (forceFinal) -1 else listener.lastTrafficRevision) ?: return@repeat
            val details = snapshot.json(listener.rule.protocol).put("final", forceFinal)
            log(listener.rule, "traffic", snapshot.message(listener.rule.protocol), details)
            listener.lastTrafficRevision = snapshot.revision
            listener.lastTrafficAt = time
            emitted++
            // At most 20 periodic summaries/second across every listener. A
            // large active set rotates fairly, rather than flooding the ring.
            if (!forceFinal && emitted >= TRAFFIC_BATCH_SIZE) return
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        channels.keys.forEach { runCatching { it.close() } }
        channels.clear()
        warmSlots.forEach { it.close() }
        warmWorkers.shutdownNow()
        sessions.keys.forEach { it.close() }
        actions.clear()
        workers.shutdownNow()
        runCatching { selector.wakeup(); selector.close() }
        // Closing sockets cancels I/O first. Drain worker/selector completions
        // before the final snapshot so successful in-flight writes are counted.
        // Do not block a service callback or try to join the current worker.
        Thread({
            runCatching { workers.awaitTermination(2, TimeUnit.SECONDS) }
            runCatching { eventThread?.join(1_000) }
            maintainTraffic(forceFinal = true)
        }, "socks5-final-stats").apply { isDaemon = true; start() }
    }

    companion object {
        private const val MAX_SESSIONS = 128
        private const val MAX_WARM_CHANNELS = 64
        private const val MAX_WARM_HANDSHAKES = 8
        private const val WARM_ROTATION_MS = 30_000L
        private const val WARM_MAINTENANCE_MS = 250L
        private const val TRAFFIC_MAINTENANCE_MS = 250L
        private const val TRAFFIC_INTERVAL_MS = 5_000L
        private const val TRAFFIC_BATCH_SIZE = 5
        private const val MAX_DATAGRAM = 65_507
        private const val WRITE_TIMEOUT_MS = 75_000
        private fun now() = System.nanoTime() / 1_000_000
        private fun remaining(deadline: Long): Int {
            val value = deadline - now()
            if (value <= 0) throw SocketTimeoutException("SOCKS5 negotiation timed out")
            return value.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        }

        private fun readBytes(input: InputStream, count: Int): ByteArray {
            val result = ByteArray(count)
            var offset = 0
            while (offset < count) {
                val read = input.read(result, offset, count - offset)
                if (read < 0) throw EOFException("SOCKS5 peer closed")
                offset += read
            }
            return result
        }

        private fun encodeAddress(address: InetAddress, port: Int): ByteArray =
            byteArrayOf(if (address.address.size == 4) 1 else 4) + address.address +
                byteArrayOf((port shr 8).toByte(), port.toByte())

        private fun readAddress(input: InputStream): Pair<InetAddress?, Int> {
            val type = input.read()
            val address = when (type) {
                1 -> InetAddress.getByAddress(readBytes(input, 4))
                4 -> InetAddress.getByAddress(readBytes(input, 16))
                3 -> {
                    val length = input.read()
                    if (length <= 0) throw IOException("Invalid SOCKS5 address")
                    readBytes(input, length)
                    null
                }
                else -> throw IOException("Invalid SOCKS5 address")
            }
            val port = readBytes(input, 2)
            return address to (((port[0].toInt() and 255) shl 8) or (port[1].toInt() and 255))
        }

        private fun skipDatagramAddress(packet: ByteBuffer) {
            val length = when (packet.get().toInt() and 255) {
                1 -> 4
                4 -> 16
                3 -> packet.get().toInt() and 255
                else -> throw IOException("Invalid SOCKS5 UDP address")
            }
            if (length == 0 || packet.remaining() < length + 2) throw IOException("Invalid SOCKS5 UDP address")
            packet.position(packet.position() + length + 2)
        }
    }
}
