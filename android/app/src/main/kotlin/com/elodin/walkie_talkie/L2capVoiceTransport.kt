package com.elodin.walkie_talkie

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.util.Log
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * L2CAP CoC (Credit-Based Flow Control) voice transport.
 *
 * The host calls [startServer] to open a listening socket on a dynamic PSM
 * in [0x80, 0xFF] odd range. Guests call [connectClient] to dial the host's
 * PSM. VoiceFrame packets flow over the established channel.
 *
 * **Framing**: L2CAP CoC is a stream protocol, but we treat one L2CAP packet
 * as one VoiceFrame (v1 choice, matching [voice_frame.dart] where
 * kVoiceMtu = 128). Each write call emits exactly one packet <= MTU bytes.
 * On receive, one read delivers one frame.
 *
 * **Known risks** documented in issue #46:
 *  - `listenUsingInsecureL2capChannel` is flaky on some OEMs; guest side
 *    retries with exponential backoff (250 ms→5 s, 5 attempts). L2CAP
 *    failure is non-fatal: a toast is shown and only the voice plane
 *    is degraded — the control plane stays usable.
 *  - Verified on Pixel + Samsung at minimum; Xiaomi / Huawei may need
 *    additional mitigation.
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
    }

    // Host-side: server socket + accepted client sockets
    private var serverSocket: android.bluetooth.BluetoothServerSocket? = null
    private var acceptThread: Thread? = null
    private val clientSockets = mutableMapOf<String, BluetoothSocket>()
    private val running = AtomicBoolean(false)

    // Guest-side: single connection to the host
    private var guestSocket: BluetoothSocket? = null
    private var guestRecvThread: Thread? = null

    // ── Host side ──────────────────────────────────────────────────────────

    /**
     * Open an L2CAP CoC server socket and return the bound PSM.
     * The PSM is dynamically assigned by Android in [0x0080, 0x00FF], odd.
     * Returns null if the server could not be opened (e.g. BT off).
     */
    fun startServer(): Int? {
        return try {
            val sock = bluetoothAdapter.listenUsingInsecureL2capChannel()
            serverSocket = sock
            val psm = sock.psm
            running.set(true)
            acceptThread = Thread({ acceptLoop(sock) }, "L2capAccept").apply { isDaemon = true; start() }
            Log.i(TAG, "L2CAP server listening on PSM 0x${psm.toString(16)}")
            psm
        } catch (e: IOException) {
            Log.e(TAG, "Failed to open L2CAP server socket: ${e.message}")
            onError("L2CAP server failed: ${e.message}")
            null
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
                if (running.get()) Log.e(TAG, "Accept error: ${e.message}")
                break
            }
        }
    }

    private fun receiveLoop(addr: String, socket: BluetoothSocket) {
        val buf = ByteArray(socket.maxReceivePacketSize.coerceAtLeast(128))
        val input = socket.inputStream
        while (socket.isConnected) {
            try {
                val n = input.read(buf)
                if (n < 8) continue // shorter than VoiceFrame header — drop
                onVoiceFrame(buf.copyOf(n))
            } catch (e: IOException) {
                Log.i(TAG, "Receive loop ended for $addr: ${e.message}")
                break
            }
        }
        synchronized(clientSockets) { clientSockets.remove(addr) }
    }

    /**
     * Send [frame] to a connected client at [addr].
     * No-op if the client is not currently connected.
     */
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
     * Retries with exponential backoff on failure. Returns true on success.
     */
    fun connectClient(macAddress: String, psm: Int): Boolean {
        val device = bluetoothAdapter.getRemoteDevice(macAddress)
        for ((i, delay) in BACKOFF_MS.withIndex()) {
            try {
                Thread.sleep(delay)
                val sock = device.createInsecureL2capChannel(psm)
                sock.connect()
                guestSocket = sock
                guestRecvThread = Thread(
                    { receiveLoop(macAddress, sock) },
                    "L2capGuestRecv"
                ).apply { isDaemon = true; start() }
                Log.i(TAG, "L2CAP connected to $macAddress PSM 0x${psm.toString(16)}")
                return true
            } catch (e: IOException) {
                Log.w(TAG, "L2CAP connect attempt ${i + 1} failed: ${e.message}")
            }
        }
        onError("L2CAP connect to $macAddress failed after ${BACKOFF_MS.size} attempts")
        return false
    }

    /**
     * Send [frame] to the host (guest-side path).
     */
    fun sendToHost(frame: ByteArray) {
        val sock = guestSocket ?: return
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
        synchronized(clientSockets) {
            clientSockets.values.forEach { try { it.close() } catch (_: IOException) {} }
            clientSockets.clear()
        }
        try { guestSocket?.close() } catch (_: IOException) {}
        guestSocket = null
        Log.i(TAG, "L2CAP transport stopped")
    }
}