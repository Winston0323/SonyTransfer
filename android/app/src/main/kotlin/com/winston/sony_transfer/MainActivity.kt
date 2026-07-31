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
import android.net.wifi.ScanResult
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
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

    companion object {
        private const val TAG = "SonyTransferWifi"
        private const val SCAN_PERMISSION_REQUEST = 1001
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
                    "unbind" -> {
                        cm.bindProcessToNetwork(null)
                        result.success(true)
                    }
                    "disconnectWifi" -> result.success(disconnectWifi(cm))
                    "wifiGateway" -> result.success(wifiGateway(cm))
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        clearScanListeners()
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
        return cm.bindProcessToNetwork(wifi)
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
