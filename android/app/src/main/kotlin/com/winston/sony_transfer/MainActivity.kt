package com.winston.sony_transfer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.ScanResult
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    private val channelName = "sony_transfer/network"
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Holds the temporary camera Wi-Fi so releasing it actually leaves the AP. */
    private var cameraCallback: ConnectivityManager.NetworkCallback? = null
    private var joinResult: MethodChannel.Result? = null
    private var scanReceiver: BroadcastReceiver? = null
    private var pendingScanResult: MethodChannel.Result? = null
    private var scanCallback: WifiManager.ScanResultsCallback? = null

    /**
     * Held only while bound to the camera. Without it several OEMs let the Wi-Fi
     * radio drop into a power-saving mode as soon as the screen dims, which is a
     * far bigger drag on throughput than anything in this app's own I/O — and it
     * hits cheaper phones much harder than a tablet that never bothers throttling.
     */
    private var wifiLock: WifiManager.WifiLock? = null

    /**
     * Held alongside [wifiLock]. Some OEMs suspend background CPU work (and with
     * it, this app's socket reads) the moment the screen times out mid-transfer —
     * a battery-saving habit tablets are less aggressive about. A partial wake
     * lock keeps the CPU itself running so a long transfer survives the screen
     * going dark.
     */
    private var cpuLock: PowerManager.WakeLock? = null

    /** Pending result for a folder pick, resolved from [onActivityResult]. */
    private var folderPickResult: MethodChannel.Result? = null

    private val prefs by lazy {
        applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    companion object {
        private const val TAG = "SonyTransferWifi"
        private const val SCAN_PERMISSION_REQUEST = 1001
        private const val FOLDER_PICK_REQUEST = 1002
        private const val PREFS_NAME = "sony_transfer_prefs"
        private const val PREF_DESTINATION_URI = "destination_tree_uri"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                when (call.method) {
                    "bindToWifi" -> result.success(bindToWifi(cm))
                    "scanCameraWifi" -> scanCameraWifi(result)
                    "joinCameraWifi" -> {
                        val ssid = call.argument<String>("ssid")?.trim().orEmpty()
                        val password = call.argument<String>("password").orEmpty()
                        if (password.isEmpty()) {
                            result.success(
                                joinOutcome(
                                    false,
                                    "bad_args",
                                    "Enter the password shown on the camera.",
                                ),
                            )
                        } else {
                            joinCameraWifi(cm, ssid, password, result)
                        }
                    }
                    "openWifiSettings" -> {
                        openWifiPanel()
                        result.success(true)
                    }
                    "openLocationSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(true)
                    }
                    "openAppSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(android.net.Uri.fromParts("package", packageName, null))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(true)
                    }
                    "currentWifiSsid" -> result.success(currentWifiSsid())
                    "wifiLinkInfo" -> result.success(wifiLinkInfo())
                    "unbind" -> {
                        cm.bindProcessToNetwork(null)
                        result.success(true)
                    }
                    "disconnectWifi" -> result.success(disconnectWifi(cm))
                    "wifiGateway" -> result.success(wifiGateway(cm))
                    "pickDestinationFolder" -> pickDestinationFolder(result)
                    "currentDestinationName" -> result.success(currentDestinationName())
                    "clearDestinationFolder" -> {
                        clearDestinationFolder()
                        result.success(true)
                    }
                    "saveFileToDestination" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        result.success(saveFileToDestination(sourcePath, fileName))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        clearScanListeners()
        releaseWifiLock()
        super.onDestroy()
    }

    /**
     * The camera's access point offers no internet, so Android keeps the default route on
     * cellular and traffic aimed at the camera never leaves the device. Pinning the whole
     * process to the Wi-Fi network is what makes the camera reachable at all.
     */
    @Suppress("DEPRECATION")
    private fun bindToWifi(cm: ConnectivityManager): Boolean {
        val wifi = wifiNetwork(cm) ?: return false
        val bound = cm.bindProcessToNetwork(wifi)
        if (bound) acquireWifiLock()
        return bound
    }

    /**
     * WIFI_MODE_FULL_LOW_LATENCY (API 29+) keeps the radio at full power the same
     * way WIFI_MODE_FULL_HIGH_PERF does, but is the mode Android actually still
     * honours on newer OEM skins that have started quietly ignoring high-perf.
     * Falling back to high-perf below API 29 covers the rest. Either way, this
     * asks the platform not to let the radio sleep between beacons to save
     * battery — invisible on a plugged-in tablet, but a real cut to a phone's
     * throughput.
     */
    @Suppress("DEPRECATION")
    private fun acquireWifiLock() {
        if (wifiLock?.isHeld != true) {
            try {
                val wifiManager =
                    applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                val lock = wifiManager.createWifiLock(mode, "$packageName:transfer")
                lock.setReferenceCounted(false)
                lock.acquire()
                wifiLock = lock
                Log.i(TAG, "wifi lock acquired (mode=$mode)")
            } catch (e: Exception) {
                Log.w(TAG, "wifi lock acquire failed", e)
            }
        }

        if (cpuLock?.isHeld != true) {
            try {
                val powerManager =
                    applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                val lock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "$packageName:transfer",
                )
                lock.setReferenceCounted(false)
                // A stuck lock would otherwise drain the battery well past any
                // real transfer; nothing in this app should ever hold it this long.
                lock.acquire(30 * 60 * 1000L)
                cpuLock = lock
                Log.i(TAG, "cpu wake lock acquired")
            } catch (e: Exception) {
                Log.w(TAG, "cpu wake lock acquire failed", e)
            }
        }
    }

    private fun releaseWifiLock() {
        wifiLock?.let { lock ->
            try {
                if (lock.isHeld) lock.release()
                Log.i(TAG, "wifi lock released")
            } catch (e: Exception) {
                Log.w(TAG, "wifi lock release failed", e)
            }
        }
        wifiLock = null

        cpuLock?.let { lock ->
            try {
                if (lock.isHeld) lock.release()
                Log.i(TAG, "cpu wake lock released")
            } catch (e: Exception) {
                Log.w(TAG, "cpu wake lock release failed", e)
            }
        }
        cpuLock = null
    }

    /**
     * PHY rate, signal strength, and band for the active Wi-Fi link, so a slow
     * transfer can be told apart from a weak or congested one. Any of these can
     * be null when Android will not report it.
     */
    @Suppress("DEPRECATION")
    private fun wifiLinkInfo(): Map<String, Int?> {
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val info = wifiManager.connectionInfo
        return mapOf(
            "linkSpeedMbps" to info?.linkSpeed?.takeIf { it > 0 },
            "rssiDbm" to info?.rssi?.takeIf { it != 0 },
            "frequencyMhz" to info?.frequency?.takeIf { it > 0 },
        )
    }

    /**
     * Lets the user redirect saved shots to any folder reachable through
     * Android's document picker — an SD card, Downloads, a synced cloud folder —
     * instead of the fixed Photos album this app defaults to.
     */
    private fun pickDestinationFolder(result: MethodChannel.Result) {
        if (folderPickResult != null) {
            result.error("busy", "A folder picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        try {
            folderPickResult = result
            startActivityForResult(intent, FOLDER_PICK_REQUEST)
        } catch (e: Exception) {
            Log.w(TAG, "folder picker unavailable", e)
            folderPickResult = null
            result.success(mapOf("ok" to false, "name" to currentDestinationName()))
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != FOLDER_PICK_REQUEST) return
        val pending = folderPickResult ?: return
        folderPickResult = null

        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pending.success(mapOf("ok" to false, "name" to currentDestinationName()))
            return
        }

        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            prefs.edit().putString(PREF_DESTINATION_URI, uri.toString()).apply()
            Log.i(TAG, "destination folder set: $uri")
            pending.success(mapOf("ok" to true, "name" to displayNameFor(uri)))
        } catch (e: Exception) {
            Log.w(TAG, "could not persist folder permission", e)
            pending.success(mapOf("ok" to false, "name" to currentDestinationName()))
        }
    }

    /** The chosen folder's tree URI, or null if none is set or its grant expired. */
    private fun destinationUri(): Uri? {
        val raw = prefs.getString(PREF_DESTINATION_URI, null) ?: return null
        val uri = Uri.parse(raw)
        val stillGranted = contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        if (!stillGranted) {
            prefs.edit().remove(PREF_DESTINATION_URI).apply()
            return null
        }
        return uri
    }

    private fun currentDestinationName(): String? =
        destinationUri()?.let { displayNameFor(it) }

    private fun displayNameFor(uri: Uri): String =
        DocumentFile.fromTreeUri(this, uri)?.name ?: uri.lastPathSegment ?: "Selected folder"

    private fun clearDestinationFolder() {
        destinationUri()?.let { uri ->
            try {
                contentResolver.releasePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (e: Exception) {
                Log.w(TAG, "releasePersistableUriPermission failed", e)
            }
        }
        prefs.edit().remove(PREF_DESTINATION_URI).apply()
    }

    /**
     * Copies an already-downloaded file at [sourcePath] into the chosen folder
     * as [fileName], overwriting any earlier copy. Dart hands over a finished
     * local file rather than streaming bytes over the channel, so this is one
     * cheap call per shot instead of one per chunk.
     */
    private fun saveFileToDestination(sourcePath: String?, fileName: String?): Map<String, Any?> {
        if (sourcePath.isNullOrEmpty() || fileName.isNullOrEmpty()) {
            return mapOf("ok" to false, "reason" to "bad_args")
        }
        val tree = destinationUri()?.let { DocumentFile.fromTreeUri(this, it) }
            ?: return mapOf("ok" to false, "reason" to "no_folder")

        return try {
            tree.findFile(fileName)?.delete()
            val target = tree.createFile(mimeTypeFor(fileName), fileName)
                ?: return mapOf("ok" to false, "reason" to "create_failed")

            val opened = contentResolver.openOutputStream(target.uri)?.use { out ->
                File(sourcePath).inputStream().use { input -> input.copyTo(out) }
                true
            } ?: false

            if (!opened) target.delete()
            mapOf("ok" to opened, "reason" to if (opened) null else "open_failed")
        } catch (e: Exception) {
            Log.w(TAG, "saveFileToDestination failed", e)
            mapOf("ok" to false, "reason" to e.javaClass.simpleName)
        }
    }

    private fun mimeTypeFor(fileName: String): String =
        when (fileName.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "heic" -> "image/heic"
            else -> "application/octet-stream"
        }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != SCAN_PERMISSION_REQUEST) return
        val pending = pendingScanResult ?: return
        pendingScanResult = null
        Log.i(
            TAG,
            "scan permissions: ${permissions.toList()} -> ${grantResults.toList()}",
        )
        performScan(pending)
    }

    private fun scanCameraWifi(result: MethodChannel.Result) {
        if (pendingScanResult != null) {
            result.error("busy", "A Wi-Fi scan is already running.", null)
            return
        }
        val missing = scanPermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            Log.i(TAG, "requesting scan permissions: $missing")
            pendingScanResult = result
            ActivityCompat.requestPermissions(
                this,
                missing.toTypedArray(),
                SCAN_PERMISSION_REQUEST,
            )
            return
        }
        performScan(result)
    }

    private fun scanPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(
                android.Manifest.permission.NEARBY_WIFI_DEVICES,
                android.Manifest.permission.ACCESS_FINE_LOCATION,
            )
        } else {
            arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        }

    @Suppress("DEPRECATION")
    private fun performScan(result: MethodChannel.Result) {
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        clearScanListeners()

        var completed = false
        var started = false

        fun finish(reason: String) {
            if (completed) return
            completed = true
            clearScanListeners()

            val all = readScanSsids(wifiManager)
            val cameras = all.filter(::looksLikeCameraSsid)

            val problem = when {
                cameras.isNotEmpty() -> null
                !wifiManager.isWifiEnabled -> "wifi_off"
                !hasScanPermission() -> "permission_denied"
                !locationEnabled() -> "location_off"
                all.isEmpty() && !started -> "throttled"
                else -> "none_found"
            }

            Log.i(
                TAG,
                "scan finish reason=$reason started=$started cameras=${cameras.size} " +
                    "all=${all.size} problem=$problem",
            )

            result.success(
                mapOf(
                    "cameras" to cameras,
                    "all" to all,
                    "problem" to problem,
                ),
            )
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val callback = object : WifiManager.ScanResultsCallback() {
                override fun onScanResultsAvailable() {
                    finish("callback")
                }
            }
            scanCallback = callback
            try {
                wifiManager.registerScanResultsCallback(mainExecutor, callback)
            } catch (e: SecurityException) {
                Log.w(TAG, "registerScanResultsCallback denied", e)
            }
        }

        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val updated = intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, true)
                Log.i(TAG, "SCAN_RESULTS_AVAILABLE updated=$updated")
                finish(if (updated) "broadcast" else "stale_broadcast")
            }
        }
        scanReceiver = receiver
        val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }

        started = try {
            wifiManager.startScan()
        } catch (e: SecurityException) {
            Log.w(TAG, "startScan denied", e)
            false
        }
        Log.i(TAG, "startScan=$started")

        if (!started) {
            // Throttled — return whatever the last system-wide scan left cached.
            finish("throttled")
            return
        }

        mainHandler.postDelayed({
            if (!completed) finish("timeout")
        }, 10_000)
    }

    private fun clearScanListeners() {
        scanReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        scanReceiver = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            scanCallback?.let { callback ->
                val wifiManager =
                    applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                try {
                    wifiManager.unregisterScanResultsCallback(callback)
                } catch (_: Exception) {
                }
            }
        }
        scanCallback = null
    }

    @Suppress("DEPRECATION")
    private fun readScanSsids(wifiManager: WifiManager): List<String> {
        val results: List<ScanResult> = try {
            wifiManager.scanResults ?: emptyList()
        } catch (e: SecurityException) {
            Log.w(TAG, "getScanResults denied", e)
            emptyList()
        }
        return results
            .mapNotNull { it.SSID?.trim()?.removeSurrounding("\"") }
            .filter { it.isNotEmpty() && it != "<unknown ssid>" }
            .distinct()
            .sorted()
    }

    /** Sony Send-to-Smartphone APs, plus a few other names cameras use. */
    private fun looksLikeCameraSsid(ssid: String): Boolean {
        val upper = ssid.uppercase()
        return upper.startsWith("DIRECT-") ||
            upper.contains("ILCE") ||
            upper.contains("DSC-") ||
            upper.contains("ZV-") ||
            (upper.contains("SONY") && upper.contains("CAM"))
    }

    private fun hasScanPermission(): Boolean = scanPermissions().any {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun locationEnabled(): Boolean {
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return true
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            lm.isLocationEnabled
        } else {
            @Suppress("DEPRECATION")
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        }
    }

    /**
     * Joins the camera AP as a temporary, app-owned network.
     *
     * WifiNetworkSpecifier does not save the network or change the tablet's normal
     * preferred Wi-Fi. Releasing [cameraCallback] drops this temporary connection.
     */
    private fun joinCameraWifi(
        cm: ConnectivityManager,
        ssid: String,
        password: String,
        result: MethodChannel.Result,
    ) {
        if (joinResult != null) {
            result.success(
                joinOutcome(false, "busy", "Already joining the camera Wi-Fi."),
            )
            return
        }

        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (!wifiManager.isWifiEnabled) {
            result.success(
                joinOutcome(
                    false,
                    "wifi_off",
                    "Wi-Fi is switched off. Turn it on, then tap Connect again.",
                ),
            )
            return
        }

        if (password.length !in 8..63) {
            result.success(
                joinOutcome(
                    false,
                    "bad_args",
                    "WPA passwords must be 8–63 characters. Check the camera screen.",
                ),
            )
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && ssid.isEmpty()) {
            result.success(
                joinOutcome(
                    false,
                    "need_ssid",
                    "Scan for the camera or enter its exact Wi-Fi name first.",
                ),
            )
            return
        }

        releaseOwnedNetwork(cm)
        joinResult = result

        try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                    Log.i(TAG, "temporary join via WifiNetworkSpecifier ssid=$ssid")
                    joinWithSpecifier(cm, ssid, password)
                }
                ssid.isEmpty() -> {
                    completeJoin(
                        false,
                        "need_ssid",
                        "Enter or scan the camera network name first.",
                    )
                }
                else -> joinWithConfiguration(cm, ssid, password)
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "join SecurityException", e)
            completeJoin(
                false,
                "denied",
                "Android blocked the temporary Wi-Fi request: ${e.message}",
            )
        } catch (e: Exception) {
            Log.e(TAG, "join failed", e)
            completeJoin(false, "error", "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun joinWithSpecifier(
        cm: ConnectivityManager,
        ssid: String,
        password: String,
    ) {
        val builder = WifiNetworkSpecifier.Builder()
            .setWpa2Passphrase(password)
            .setSsid(ssid.removeSurrounding("\""))

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(builder.build())
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.i(TAG, "specifier onAvailable")
                cm.bindProcessToNetwork(network)
                acquireWifiLock()
                completeJoin(true)
            }

            override fun onUnavailable() {
                Log.i(TAG, "temporary specifier onUnavailable")
                cameraCallback = null
                completeJoin(
                    false,
                    "unavailable",
                    "Android did not create the temporary connection to $ssid. " +
                        "Keep Send to Smartphone open on the camera and try again.",
                )
            }

            override fun onLost(network: Network) {
                cm.bindProcessToNetwork(null)
                releaseWifiLock()
            }
        }

        cameraCallback = callback
        cm.requestNetwork(request, callback, mainHandler, 30_000)
    }

    @Suppress("DEPRECATION")
    private fun joinWithConfiguration(
        cm: ConnectivityManager,
        ssid: String,
        password: String,
    ) {
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val quotedSsid = "\"${ssid.removeSurrounding("\"")}\""
        val config = WifiConfiguration().apply {
            SSID = quotedSsid
            preSharedKey = "\"$password\""
            allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK)
        }

        var networkId = wifiManager.addNetwork(config)
        if (networkId == -1) {
            networkId = wifiManager.configuredNetworks
                ?.firstOrNull { it.SSID == quotedSsid }
                ?.networkId
                ?: -1
        }
        if (networkId == -1 || !wifiManager.enableNetwork(networkId, true)) {
            openWifiPanel()
            completeJoin(
                false,
                "opened_settings",
                "Could not add the network in-app. Join it in Wi-Fi Settings, then return.",
            )
            return
        }

        wifiManager.reconnect()

        mainHandler.postDelayed({
            val bound = bindToWifi(cm)
            completeJoin(
                bound,
                if (bound) null else "opened_settings",
                if (bound) {
                    null
                } else {
                    openWifiPanel()
                    "Joined $ssid but no Wi-Fi route appeared. Check Wi-Fi Settings."
                },
            )
        }, 2_500)
    }

    private fun joinOutcome(ok: Boolean, code: String?, message: String?) =
        mapOf("ok" to ok, "code" to code, "message" to message)

    private fun completeJoin(ok: Boolean, code: String? = null, message: String? = null) {
        val pending = joinResult ?: return
        joinResult = null
        Log.i(TAG, "completeJoin ok=$ok code=$code message=$message")
        pending.success(joinOutcome(ok, code, message))
    }

    @Suppress("DEPRECATION")
    private fun disconnectWifi(cm: ConnectivityManager): String {
        cm.bindProcessToNetwork(null)
        releaseWifiLock()

        val owned = cameraCallback != null
        releaseOwnedNetwork(cm)
        if (owned) return "released"

        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val networkId = wifiManager.connectionInfo?.networkId ?: -1
        var forgotten = false
        if (networkId != -1) {
            forgotten = wifiManager.removeNetwork(networkId)
            if (forgotten) wifiManager.saveConfiguration()
        }
        val disconnected = wifiManager.disconnect()

        if (forgotten) return "released"

        openWifiPanel()
        return if (disconnected) "opened_settings" else "failed"
    }

    private fun releaseOwnedNetwork(cm: ConnectivityManager) {
        val callback = cameraCallback ?: return
        cameraCallback = null
        try {
            cm.unregisterNetworkCallback(callback)
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun openWifiPanel() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Intent(Settings.Panel.ACTION_WIFI)
        } else {
            Intent(Settings.ACTION_WIFI_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    @Suppress("DEPRECATION")
    private fun currentWifiSsid(): String? {
        if (ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.ACCESS_FINE_LOCATION,
            ) != PackageManager.PERMISSION_GRANTED &&
            (
                Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    ContextCompat.checkSelfPermission(
                        this,
                        android.Manifest.permission.NEARBY_WIFI_DEVICES,
                    ) != PackageManager.PERMISSION_GRANTED
                )
        ) {
            return null
        }
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val raw = wifiManager.connectionInfo?.ssid ?: return null
        val ssid = raw.trim().removeSurrounding("\"")
        return ssid.takeIf { it.isNotEmpty() && it != "<unknown ssid>" }
    }

    private fun wifiGateway(cm: ConnectivityManager): String? {
        val wifi = wifiNetwork(cm) ?: return null
        val props = cm.getLinkProperties(wifi) ?: return null

        props.routes
            .firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }
            ?.gateway?.hostAddress
            ?.let { return it }

        return firstHostOnSubnet(props)
    }

    private fun firstHostOnSubnet(props: LinkProperties): String? {
        val link = props.linkAddresses.firstOrNull { it.address is Inet4Address } ?: return null
        val prefix = link.prefixLength
        if (prefix !in 1..30) return null

        val address = ByteBuffer.wrap(link.address.address).int
        val mask = -1 shl (32 - prefix)
        val firstHost = (address and mask) + 1

        val bytes = ByteBuffer.allocate(4).putInt(firstHost).array()
        return InetAddress.getByAddress(bytes).hostAddress
    }

    @Suppress("DEPRECATION")
    private fun wifiNetwork(cm: ConnectivityManager) = cm.allNetworks.firstOrNull { network ->
        cm.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }
}
