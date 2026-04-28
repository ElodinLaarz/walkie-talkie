package com.elodin.walkie_talkie

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.util.Log
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * L2CAP CoC (Credit-Based Flow Control) voice transport.
 *
 * The host calls [startServer] to open a listening socket on a dynamic PSM
 * in [0x80, 0xFF] odd range. Guests call [connectClient] to dial the host's
 * PSM. VoiceFrame packets flow over the established channel.
 *
 * **Framing (v1)**: L2CAP CoC is a stream protocol. For v1 we treat each
 * [sendToClient]/[sendToHost] call as one L2CAP packet by keeping frames
 * under kVoiceMtu = 128 bytes, which fits inside a single MTU. Full
 * length-prefixed reassembly is deferred to a future issue; callers must
 * ensure every write is a complete VoiceFrame (<=128 bytes) so receive-side
 * reads stay aligned.
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
        private const val VOICE_MTU = 128
    }

    // Host-side: server socket + accepted client sockets
    private var serverSocket: android.bluetooth.BluetoothServerSocket? = null
    private var activePsm: Int = -1
    private var acceptThread: Thread? = null
    private val clientSockets = mutableMapOf<String, BluetoothSocket>()
    private val running = AtomicBoolean(false)

    // Guest-side: single connection to the host
    private var guestSocket: BluetoothSocket? = null
    private var guestRecvThread: Thread? = null

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
                synchronized(clientSockets) { clientSockets[addr] = client }
                onClientConnected(addr)
                Thread({ receiveLoop(addr, client) }, "L2capRecv-$addr").apply {
                    isDaemon = true; start()
                }
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

    private fun receiveLoop(addr: String, socket: BluetoothSocket) {
        val buf = ByteArray(VOICE_MTU.coerceAtLeast(socket.maxReceivePacketSize))
        try {
            val input = socket.inputStream
            while (socket.isConnected) {
                try {
                    val n = input.read(buf)
                    if (n <= 0) break  // EOF
                    if (n < 8) continue // shorter than VoiceFrame header — drop
                    onVoiceFrame(buf.copyOf(n))
                } catch (e: IOException) {
                    Log.i(TAG, "Receive loop ended for $addr: ${e.message}")
                    break
                }
            }
        } finally {
            synchronized(clientSockets) { clientSockets.remove(addr) }
            try { socket.close() } catch (_: IOException) {}
        }
    }

    /** Send [frame] to a connected client at [addr]. No-op if not connected. */
    fun sendToClient(addr: String, frame: ByteArray) {
        val sock = synchronized(clientSockets) { clientSockets[addr] } ?: return
        try {
            sock.outputStream.write(frame)
        } catch (e: IOException) {
            Log.w(TAG, "Send to $addr failed: ${e.message}")
        }
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
        // Close any existing guest socket before dialling a new one.
        synchronized(this) {
            guestSocket?.let { try { it.close() } catch (_: IOException) {} }
            guestSocket = null
        }

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
                synchronized(this) { guestSocket = sock }
                guestRecvThread = Thread(
                    { receiveLoop(macAddress, sock) },
                    "L2capGuestRecv"
                ).apply { isDaemon = true; start() }
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
        val sock = synchronized(this) { guestSocket } ?: return
        try {
            sock.outputStream.write(frame)
        } catch (e: IOException) {
            Log.w(TAG, "Send to host failed: ${e.message}")
        }
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    fun stop() {
        running.set(false)
        try { serverSocket?.close() } catch (_: IOException) {}
        synchronized(this) {
            serverSocket = null
            activePsm = -1
        }
        synchronized(clientSockets) {
            clientSockets.values.forEach { try { it.close() } catch (_: IOException) {} }
            clientSockets.clear()
        }
        synchronized(this) {
            guestSocket?.let { try { it.close() } catch (_: IOException) {} }
            guestSocket = null
        }
        Log.i(TAG, "L2CAP transport stopped")
    }
}