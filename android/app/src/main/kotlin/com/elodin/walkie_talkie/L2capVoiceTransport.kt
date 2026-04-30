package com.elodin.walkie_talkie

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.util.Log
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * L2CAP CoC (Credit-Based Flow Control) voice transport.
 *
 * The host calls [startServer] to open a listening socket on a dynamic PSM
 * in [0x80, 0xFF] odd range. Guests call [connectClient] to dial the host's
 * PSM. VoiceFrame packets flow over the established channel.
 *
 * **Framing (v1.1)**: L2CAP CoC is a stream protocol. To keep frame
 * boundaries deterministic across OEMs (some kernels coalesce multiple
 * SDUs into one userspace `read`), every L2CAP write is preceded by a
 * 2-byte big-endian length prefix carrying the size of the VoiceFrame
 * payload that follows. Receivers read the prefix, then exactly that
 * many bytes, then dispatch the inner bytes to [onVoiceFrame] — exactly
 * the same payload the original v1 spec described, just framed at the
 * transport layer instead of relying on packet boundaries.
 *
 * **Thread model**: each connected socket owns one *writer* thread and
 * one *reader* thread. Producers (audio capture, heartbeats, …) call
 * [sendToHost] / [sendToClient], which push onto a bounded
 * [LinkedBlockingQueue]; the writer drains the queue and serialises
 * writes onto the socket so concurrent producers can never tear a frame.
 * The reader runs the framed-read loop. [stop] signals shutdown via a
 * sentinel + socket close, then joins both threads with a short timeout
 * so callers (the foreground service) can fully tear down between
 * sessions without leaking threads.
 *
 * **Known risks** documented in issue #46:
 *  - `listenUsingInsecureL2capChannel` is flaky on some OEMs; guest side
 *    retries with exponential backoff (250 ms→5 s, 5 attempts). L2CAP
 *    failure is non-fatal — the control plane stays usable.
 *  - Verified API surface on Pixel + Samsung at minimum.
 */
class L2capVoiceTransport(
    private val bluetoothAdapter: BluetoothAdapter,
    private val onVoiceFrame: (ByteArray) -> Unit,
    private val onClientConnected: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    companion object {
        private const val TAG = "L2capVoiceTransport"
        private val BACKOFF_MS = longArrayOf(250, 500, 1000, 2000, 5000)

        /**
         * Per-socket send queue capacity. ~64 frames at one-per-20-ms is
         * ~1.3 s of audio. Above this, the link can't keep up; we drop
         * the oldest frame so latency stays bounded instead of blocking
         * the audio capture thread.
         */
        const val SEND_QUEUE_CAPACITY = 64

        /** Length-prefix size: 2 bytes big-endian. */
        const val LENGTH_PREFIX_SIZE = 2

        /**
         * Defensive ceiling on the length-prefix value. The protocol
         * caps voice frames at [GattConstants.VOICE_MTU] (= 128); we
         * accept up to 4 KB so future header growth has headroom and a
         * malformed peer can't trick us into allocating gigabytes.
         */
        const val MAX_FRAME_SIZE = 4096

        /** How long to wait for worker threads to drain on [stop]. */
        private const val JOIN_TIMEOUT_MS = 500L
    }

    /**
     * Per-socket I/O bundle. We keep a strong reference to both threads
     * so [stop] (and the per-link cleanup path on the guest side) can
     * join them rather than leaking them to GC.
     */
    private class SocketIo(
        val socket: BluetoothSocket,
        val sendQueue: LinkedBlockingQueue<ByteArray>,
        var recvThread: Thread? = null,
        var writerThread: Thread? = null,
    )

    /** Sentinel pushed onto the send queue to terminate the writer thread. */
    private val shutdownSentinel = ByteArray(0)

    // Host-side: server socket + accepted client sockets
    private var serverSocket: android.bluetooth.BluetoothServerSocket? = null
    private var activePsm: Int = -1
    private var acceptThread: Thread? = null
    private val clientSockets = mutableMapOf<String, SocketIo>()
    private val running = AtomicBoolean(false)

    // Guest-side: single connection to the host
    private var guestIo: SocketIo? = null

    // ── Host side ──────────────────────────────────────────────────────────

    /**
     * Open an L2CAP CoC server socket and return the bound PSM.
     * Idempotent — returns the existing PSM if the server is already running.
     */
    fun startServer(): Int? {
        synchronized(this) {
            if (activePsm >= 0) {
                Log.d(TAG, "Server already running on PSM 0x${activePsm.toString(16)}")
                return activePsm
            }
            return try {
                val sock = bluetoothAdapter.listenUsingInsecureL2capChannel()
                serverSocket = sock
                activePsm = sock.psm
                running.set(true)
                acceptThread = Thread({ acceptLoop(sock) }, "L2capAccept").apply {
                    isDaemon = true; start()
                }
                Log.i(TAG, "L2CAP server listening on PSM 0x${activePsm.toString(16)}")
                activePsm
            } catch (e: IOException) {
                Log.e(TAG, "Failed to open L2CAP server socket: ${e.message}")
                onError("L2CAP server failed: ${e.message}")
                null
            }
        }
    }

    private fun acceptLoop(serverSock: android.bluetooth.BluetoothServerSocket) {
        while (running.get()) {
            try {
                val client = serverSock.accept()
                val addr = client.remoteDevice.address
                Log.i(TAG, "L2CAP client connected: $addr")
                // Insert into the map *before* starting threads so the recv
                // thread's finally-block remove() can never fire ahead of the
                // put() if the peer disconnects immediately.
                val io = SocketIo(client, LinkedBlockingQueue(SEND_QUEUE_CAPACITY))
                synchronized(clientSockets) { clientSockets[addr] = io }
                startSocketIoThreads(addr, io)
                onClientConnected(addr)
            } catch (e: IOException) {
                if (!running.get()) break
                Log.e(TAG, "Accept error: ${e.message}")
                try {
                    Thread.sleep(250)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
            }
        }
    }

    /** Send [frame] to a connected client at [addr]. No-op if not connected. */
    fun sendToClient(addr: String, frame: ByteArray) {
        val io = synchronized(clientSockets) { clientSockets[addr] } ?: return
        enqueueFrame(io, frame)
    }

    // ── Guest side ─────────────────────────────────────────────────────────

    /**
     * Connect to the host's L2CAP CoC socket at [macAddress]:[psm].
     * Validates PSM range and MAC, catches broad exceptions, retries with
     * exponential backoff. Returns true on success, false otherwise.
     */
    fun connectClient(macAddress: String, psm: Int): Boolean {
        // Validate before hitting the BT stack so bad args return false cleanly.
        if (psm < 0x80 || psm > 0xFF || psm % 2 == 0) {
            Log.e(TAG, "Invalid PSM: 0x${psm.toString(16)} — must be odd in [0x80, 0xFF]")
            onError("Invalid voice PSM 0x${psm.toString(16)}")
            return false
        }
        // Tear down any existing guest connection before dialling a new one.
        // Snapshot under the lock, then join the worker threads outside it
        // so we never block other callers (sendToHost, stop) while waiting.
        val prev = synchronized(this) {
            val p = guestIo
            guestIo = null
            p
        }
        prev?.let { stopSocketIo(it) }

        val device = try {
            bluetoothAdapter.getRemoteDevice(macAddress)
        } catch (e: Exception) {
            Log.e(TAG, "getRemoteDevice($macAddress) failed: ${e.message}")
            onError("Invalid MAC address: $macAddress")
            return false
        }

        for ((i, delay) in BACKOFF_MS.withIndex()) {
            var sock: BluetoothSocket? = null
            try {
                Thread.sleep(delay)
                sock = device.createInsecureL2capChannel(psm)
                sock.connect()
                val io = SocketIo(sock, LinkedBlockingQueue(SEND_QUEUE_CAPACITY))
                synchronized(this) { guestIo = io }
                startSocketIoThreads(macAddress, io)
                Log.i(TAG, "L2CAP connected to $macAddress PSM 0x${psm.toString(16)}")
                return true
            } catch (e: Exception) {
                Log.w(TAG, "L2CAP connect attempt ${i + 1} failed: ${e.message}")
                try { sock?.close() } catch (_: IOException) {}
            }
        }
        onError("L2CAP connect to $macAddress failed after ${BACKOFF_MS.size} attempts")
        return false
    }

    /** Send [frame] to the host (guest-side path). */
    fun sendToHost(frame: ByteArray) {
        val io = synchronized(this) { guestIo } ?: return
        enqueueFrame(io, frame)
    }

    // ── Per-socket worker plumbing ─────────────────────────────────────────

    /**
     * Start the reader + writer threads for [io]. Splitting thread spawn
     * from [SocketIo] construction lets callers insert the bundle into
     * their tracking map *first*, so the recv-thread's remove-on-EOF
     * finally never races ahead of the insert.
     */
    private fun startSocketIoThreads(addr: String, io: SocketIo) {
        io.recvThread = Thread({ receiveLoop(addr, io.socket) }, "L2capRecv-$addr").apply {
            isDaemon = true; start()
        }
        io.writerThread = Thread({ writerLoop(addr, io.socket.outputStream, io.sendQueue) }, "L2capWriter-$addr").apply {
            isDaemon = true; start()
        }
    }

    /**
     * Drain the per-socket queue and write each frame as a
     * length-prefixed payload. Exits when the writer pulls
     * [shutdownSentinel] off the queue, on I/O error, or on interrupt.
     *
     * This is the *only* thread that touches [out] — concurrent producers
     * push to [queue] but never write directly to the socket. That's what
     * eliminates the torn-frame race that issue #101 reports.
     */
    private fun writerLoop(addr: String, out: OutputStream, queue: LinkedBlockingQueue<ByteArray>) {
        try {
            while (true) {
                val frame = queue.take()
                if (frame === shutdownSentinel) break
                if (frame.isEmpty()) continue
                if (frame.size > MAX_FRAME_SIZE) {
                    Log.w(TAG, "Dropping oversized frame (${frame.size}B) for $addr")
                    continue
                }
                try {
                    writeFramed(out, frame)
                } catch (e: IOException) {
                    Log.i(TAG, "Writer for $addr ended: ${e.message}")
                    break
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun receiveLoop(addr: String, socket: BluetoothSocket) {
        try {
            val input = DataInputStream(socket.inputStream)
            while (socket.isConnected) {
                val frame = try {
                    readFramed(input)
                } catch (e: IOException) {
                    Log.i(TAG, "Receive loop ended for $addr: ${e.message}")
                    break
                } ?: break // EOF
                if (frame.size < 8) {
                    // VoiceFrame requires the 8-byte header — drop and keep
                    // reading; a malformed peer can't lock us out.
                    Log.w(TAG, "Frame from $addr shorter than VoiceFrame header — dropping")
                    continue
                }
                onVoiceFrame(frame)
            }
        } catch (e: IOException) {
            // Defensive — DataInputStream construction shouldn't throw, but
            // BluetoothSocket.getInputStream() can if the socket closed
            // racy with this thread starting.
            Log.i(TAG, "Receive loop init failed for $addr: ${e.message}")
        } finally {
            // Drop both the host-side (clientSockets) and guest-side (guestIo)
            // reference for whichever socket this loop was bound to. The
            // guest check is identity-based (socket ===) so a fresh
            // connection that races a stale receiveLoop's finally can't
            // accidentally null out the new guestIo.
            synchronized(clientSockets) { clientSockets.remove(addr) }
            synchronized(this) {
                if (guestIo?.socket === socket) guestIo = null
            }
            try { socket.close() } catch (_: IOException) {}
        }
    }

    /**
     * Push [frame] onto [io]'s send queue. If the queue is full
     * (producers outpacing the link), drop the *oldest* frame — voice is
     * latency-sensitive, and stale audio is worse than missing audio.
     */
    private fun enqueueFrame(io: SocketIo, frame: ByteArray) {
        if (frame.isEmpty()) return
        if (!io.sendQueue.offer(frame)) {
            io.sendQueue.poll() // drop oldest
            io.sendQueue.offer(frame)
        }
    }

    /**
     * Cleanly stop a socket's I/O workers: enqueue the shutdown
     * sentinel, close the socket to unblock the reader, then join both
     * threads with a bounded timeout. Anything still alive after
     * the timeout gets interrupted as a fallback.
     */
    private fun stopSocketIo(io: SocketIo) {
        // Signal the writer first; clearing the queue avoids one last
        // enqueued frame slipping out after stop.
        io.sendQueue.clear()
        io.sendQueue.offer(shutdownSentinel)
        // Closing the socket unblocks readFully() in the recv loop and
        // breaks any in-progress write() in the writer loop.
        try { io.socket.close() } catch (_: IOException) {}

        io.recvThread?.let { joinOrInterrupt(it) }
        io.writerThread?.let { joinOrInterrupt(it) }
    }

    private fun joinOrInterrupt(t: Thread) {
        try {
            t.join(JOIN_TIMEOUT_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        if (t.isAlive) t.interrupt()
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    fun stop() {
        running.set(false)
        try { serverSocket?.close() } catch (_: IOException) {}
        synchronized(this) {
            serverSocket = null
            activePsm = -1
        }
        // Snapshot under lock so we can join without holding it.
        val hostIos: List<SocketIo>
        synchronized(clientSockets) {
            hostIos = clientSockets.values.toList()
            clientSockets.clear()
        }
        hostIos.forEach { stopSocketIo(it) }
        val guest = synchronized(this) {
            val g = guestIo
            guestIo = null
            g
        }
        guest?.let { stopSocketIo(it) }
        // Join the accept thread last; closing the server socket above
        // unblocks accept() with an IOException, which the loop treats
        // as a shutdown signal once running == false.
        acceptThread?.let { joinOrInterrupt(it) }
        acceptThread = null
        Log.i(TAG, "L2CAP transport stopped")
    }

    /**
     * Test hook: snapshot the number of currently-tracked client sockets.
     * Real code shouldn't need this, but instrumented tests do.
     */
    internal fun activeClientCount(): Int =
        synchronized(clientSockets) { clientSockets.size }
}

// ── Framing helpers (package-private for unit tests) ───────────────────────

/**
 * Write [frame] to [out] as a 2-byte big-endian length prefix followed by
 * the frame bytes. The length carries only the frame size — the prefix
 * itself is *not* counted, matching common framed-protocol convention.
 *
 * Throws [IllegalArgumentException] if the frame exceeds
 * [L2capVoiceTransport.MAX_FRAME_SIZE]; throws [IOException] if the
 * underlying stream errors mid-write.
 */
internal fun writeFramed(out: OutputStream, frame: ByteArray) {
    require(frame.size <= L2capVoiceTransport.MAX_FRAME_SIZE) {
        "Frame size ${frame.size} exceeds MAX_FRAME_SIZE ${L2capVoiceTransport.MAX_FRAME_SIZE}"
    }
    // Single buffer + single write avoids interleaving prefix and payload
    // if a future caller ever shares the OutputStream across threads (the
    // writer thread doesn't, but the API leaves no foot-gun). Writing the
    // length bytes directly into the head of `buf` saves a per-frame
    // ByteArray allocation + arraycopy, which matters at 50 fps voice.
    val buf = ByteArray(L2capVoiceTransport.LENGTH_PREFIX_SIZE + frame.size)
    buf[0] = ((frame.size ushr 8) and 0xff).toByte()
    buf[1] = (frame.size and 0xff).toByte()
    System.arraycopy(frame, 0, buf, L2capVoiceTransport.LENGTH_PREFIX_SIZE, frame.size)
    out.write(buf)
    out.flush()
}

/**
 * Read one length-prefixed frame from [input]. Returns the frame bytes
 * (without the length prefix), or `null` on clean EOF *before* any bytes
 * of a new frame have been read.
 *
 * Throws [IOException] if the stream errors mid-frame, or if the length
 * prefix is zero / exceeds [L2capVoiceTransport.MAX_FRAME_SIZE].
 */
internal fun readFramed(input: DataInputStream): ByteArray? {
    val hi = input.read()
    if (hi < 0) return null // clean EOF before a frame started
    val lo = input.read()
    if (lo < 0) throw IOException("EOF mid-prefix (after high byte)")
    val len = (hi shl 8) or lo
    if (len <= 0 || len > L2capVoiceTransport.MAX_FRAME_SIZE) {
        throw IOException("Invalid frame length $len")
    }
    val buf = ByteArray(len)
    input.readFully(buf)
    return buf
}

/**
 * Adapter for [readFramed] that takes a plain [InputStream]; tests
 * sometimes have a `ByteArrayInputStream` and don't want to hand-wrap.
 */
internal fun readFramed(input: InputStream): ByteArray? =
    readFramed(if (input is DataInputStream) input else DataInputStream(input))
