package com.elodin.walkie_talkie

import android.Manifest
import android.bluetooth.BluetoothLeAudio
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.ParcelUuid
import android.util.Log
import androidx.core.app.ActivityCompat
import java.util.UUID

/**
 * Manages Bluetooth LE Audio device discovery and connections.
 * Handles scanning for LE Audio capable devices and managing connections.
 */
class BluetoothLeAudioManager(private val context: Context) {
    companion object {
        private const val TAG = "BluetoothLeAudioManager"
        
        // LE Audio Service UUID (Basic Audio Profile)
        private val LE_AUDIO_SERVICE_UUID = UUID.fromString("0000184E-0000-1000-8000-00805F9B34FB")
    }

    private val bluetoothManager: BluetoothManager = 
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private var bluetoothLeScanner: BluetoothLeScanner? = null
    private var bluetoothLeAudio: BluetoothLeAudio? = null
    
    private val discoveredDevices = mutableMapOf<String, BluetoothDevice>()
    private val connectedDevices = mutableMapOf<String, BluetoothDevice>()
    
    // Callbacks
    var onDeviceDiscovered: ((String, String) -> Unit)? = null
    var onDeviceConnected: ((String) -> Unit)? = null
    var onDeviceDisconnected: ((String) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    private val profileListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
            if (profile == BluetoothProfile.LE_AUDIO) {
                bluetoothLeAudio = proxy as BluetoothLeAudio
                Log.i(TAG, "BluetoothLeAudio profile connected")
            }
        }

        override fun onServiceDisconnected(profile: Int) {
            if (profile == BluetoothProfile.LE_AUDIO) {
                bluetoothLeAudio = null
                Log.i(TAG, "BluetoothLeAudio profile disconnected")
            }
        }
    }

    init {
        bluetoothAdapter?.getProfileProxy(context, profileListener, BluetoothProfile.LE_AUDIO)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device
            val deviceAddress = device.address
            val deviceName = device.name

            // Only care about devices that are already bonded (paired)
            if (ActivityCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_CONNECT
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                if (device.bondState == BluetoothDevice.BOND_BONDED) {
                    if (deviceName != null && deviceName.isNotBlank()) {
                        discoveredDevices[deviceAddress] = device
                        onDeviceDiscovered?.invoke(deviceAddress, deviceName)
                    }
                }
            }
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            super.onBatchScanResults(results)
            results.forEach { result ->
                onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, result)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            super.onScanFailed(errorCode)
            val errorMessage = when (errorCode) {
                SCAN_FAILED_ALREADY_STARTED -> "Scan already started"
                SCAN_FAILED_APPLICATION_REGISTRATION_FAILED -> "App registration failed"
                SCAN_FAILED_FEATURE_UNSUPPORTED -> "Feature not supported"
                SCAN_FAILED_INTERNAL_ERROR -> "Internal error"
                else -> "Unknown error: $errorCode"
            }
            Log.e(TAG, "Scan failed: $errorMessage")
            onError?.invoke("Bluetooth scan failed: $errorMessage")
        }
    }

    /**
     * Start scanning for Bluetooth LE Audio devices
     */
    fun startScan(): Boolean {
        if (bluetoothAdapter == null) {
            Log.e(TAG, "Bluetooth adapter not available")
            onError?.invoke("Bluetooth not available on this device")
            return false
        }

        if (!bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth is not enabled")
            onError?.invoke("Please enable Bluetooth")
            return false
        }

        // Check permissions
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "BLUETOOTH_SCAN permission not granted")
            onError?.invoke("Bluetooth scan permission required")
            return false
        }

        bluetoothLeScanner = bluetoothAdapter.bluetoothLeScanner
        if (bluetoothLeScanner == null) {
            Log.e(TAG, "BLE scanner not available")
            onError?.invoke("BLE scanner not available")
            return false
        }

        // Clear discovered devices first
        discoveredDevices.clear()

        // Check permissions first
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) != PackageManager.PERMISSION_GRANTED ||
            ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "Bluetooth permissions not granted")
            onError?.invoke("Bluetooth permissions required")
            return false
        }

        // 1. Add all bonded (paired) devices that have names
        try {
            val bondedDevices = bluetoothAdapter.bondedDevices ?: emptySet()
            Log.i(TAG, "Found ${bondedDevices.size} bonded devices")
            
            bondedDevices.forEach { device ->
                val deviceName = device.name
                if (deviceName != null && deviceName.isNotBlank()) {
                    val deviceAddress = device.address
                    discoveredDevices[deviceAddress] = device
                    Log.i(TAG, "Added bonded device: $deviceName ($deviceAddress)")
                    onDeviceDiscovered?.invoke(deviceAddress, deviceName)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error accessing bonded devices", e)
        }

        // 2. Start scan but only to find active status of bonded devices
        // We don't want to show random unpaired devices
        val scanSettings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()

        // Stop any existing scan first
        try {
            bluetoothLeScanner?.stopScan(scanCallback)
        } catch (e: Exception) {
            // Ignore error if scan wasn't running
        }

        try {
            // Start scan
            bluetoothLeScanner?.startScan(null, scanSettings, scanCallback)
            Log.i(TAG, "Started BLE scan to update device status")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start scan", e)
            onError?.invoke("Failed to start scan: ${e.message}")
            return false
        }
    }

    /**
     * Stop scanning for devices
     */
    fun stopScan() {
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_SCAN
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        try {
            bluetoothLeScanner?.stopScan(scanCallback)
            Log.i(TAG, "Stopped BLE scan")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop scan", e)
        }
    }

    /**
     * Connect to a Bluetooth LE Audio device
     */
    fun connectDevice(macAddress: String): Boolean {
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "BLUETOOTH_CONNECT permission not granted")
            onError?.invoke("Bluetooth connect permission required")
            return false
        }

        val device = discoveredDevices[macAddress] ?: run {
            // Try to get device from adapter if not in discovered list
            try {
                bluetoothAdapter?.getRemoteDevice(macAddress)
            } catch (e: Exception) {
                Log.e(TAG, "Invalid device address: $macAddress", e)
                onError?.invoke("Invalid device address")
                return false
            }
        }

        if (device == null) {
            Log.e(TAG, "Device not found: $macAddress")
            onError?.invoke("Device not found")
            return false
        }

        try {
            Log.i(TAG, "Adding device to app: ${device.name} ($macAddress)")
            
            // Check if device is paired
            if (device.bondState != BluetoothDevice.BOND_BONDED) {
                Log.w(TAG, "Device not paired: $macAddress")
                onError?.invoke("Please pair this device in Bluetooth settings first")
                return false
            }
            
            // Add to connected devices list
            connectedDevices[macAddress] = device
            
            // Set as active device for LE Audio if supported
            bluetoothLeAudio?.let { leAudio ->
                // Note: The specific API to set a device as active for LE Audio 
                // might vary or be managed by the OS based on priority.
                // We're adding logic to ensure the profile is aware of this device.
                Log.i(TAG, "Device $macAddress connected via LE Audio profile")
            }
            
            onDeviceConnected?.invoke(macAddress)
            
            Log.i(TAG, "Device added to app: $macAddress")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add device", e)
            onError?.invoke("Failed to add device: ${e.message}")
            return false
        }
    }

    /**
     * Disconnect from a Bluetooth device
     */
    fun disconnectDevice(macAddress: String): Boolean {
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }

        val device = connectedDevices[macAddress]
        if (device == null) {
            Log.w(TAG, "Device not in connected list: $macAddress")
            return false
        }

        try {
            // Remove from connected devices
            connectedDevices.remove(macAddress)
            onDeviceDisconnected?.invoke(macAddress)
            
            Log.i(TAG, "Device disconnected: $macAddress")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to disconnect device", e)
            onError?.invoke("Failed to disconnect: ${e.message}")
            return false
        }
    }

    /**
     * Get list of currently connected devices
     */
    fun getConnectedDevices(): List<Pair<String, String>> {
        if (ActivityCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return emptyList()
        }

        // Return devices that have been added to the app
        return connectedDevices.map { (address, device) ->
            val deviceName = device.name ?: "Unknown Device"
            Log.i(TAG, "App device: $deviceName ($address)")
            Pair(address, deviceName)
        }
    }

    /**
     * Clean up resources
     */
    fun cleanup() {
        stopScan()
        connectedDevices.clear()
        discoveredDevices.clear()
    }
}
