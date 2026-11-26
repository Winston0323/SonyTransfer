package com.winston.sony_transfer

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.mtp.MtpConstants
import android.mtp.MtpDevice
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import androidx.exifinterface.media.ExifInterface
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import me.jahnen.libaums.core.UsbMassStorageDevice
import me.jahnen.libaums.core.fs.UsbFile
import me.jahnen.libaums.core.fs.UsbFileInputStream
import me.jahnen.libaums.core.fs.UsbFileStreamFactory
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Locale

/**
 * Cable transfer against a Sony body over USB.
 *
 * Backends, tried in order:
 * 1. **libaums** — userspace FAT32 reader (kernel must not own the MSC interface;
 *    cannot read exFAT/SDXC).
 * 2. **Mounted volumes** — StorageManager paths the OS already mounted (exFAT OK).
 * 3. **MediaStore** — secondary volumes indexed by the media scanner.
 * 4. **MTP** — last resort when the phone keeps the camera in still-image/MTP
 *    mode (common on vivo). Usually Slot 1 only on A7R III.
 */
class UsbMassStorage(private val activity: MainActivity) {
    private val usbManager =
        activity.getSystemService(Context.USB_SERVICE) as UsbManager

    private var eventSink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null

    /** Opened card volumes, indexed in the order Dart sees them. */
    private var openVolumes: List<OpenVolume> = emptyList()

    /** Shared MTP session (many Android phones force Sony into MTP). */
    private var mtpDevice: MtpDevice? = null
    private var mtpConnection: UsbDeviceConnection? = null

    private sealed class OpenVolume {
        abstract val labelHint: String

        class Libaums(
            val device: UsbMassStorageDevice,
            val root: UsbFile,
            override val labelHint: String,
        ) : OpenVolume()

        class Mounted(
            val rootDir: File,
            override val labelHint: String,
        ) : OpenVolume()

        /** Secondary volume indexed by the media scanner (exFAT-friendly). */
        class Media(
            val volumeName: String,
            override val labelHint: String,
        ) : OpenVolume()

        /** One MTP storage unit — on A7R III usually Slot 1 only. */
        class Mtp(
            val storageId: Int,
            override val labelHint: String,
        ) : OpenVolume()
    }

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_USB_PERMISSION) return
            val device: UsbDevice? =
                if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                }
            val granted =
                intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            val pending = permissionResult
            permissionResult = null
            Log.i(TAG, "USB permission granted=$granted device=${device?.deviceName}")
            pending?.success(
                mapOf(
                    "ok" to granted,
                    "attached" to hasSonyMassStorage(),
                    "hasPermission" to (device != null && usbManager.hasPermission(device)),
                ),
            )
            if (granted) emit("attached")
        }
    }

    private val hotplugReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    Log.i(TAG, "USB device attached")
                    emit("attached")
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    Log.i(TAG, "USB device detached")
                    close()
                    emit("detached")
                }
            }
        }
    }

    fun attachEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun register() {
        val permissionFilter = IntentFilter(ACTION_USB_PERMISSION)
        val hotplugFilter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(
                permissionReceiver,
                permissionFilter,
                Context.RECEIVER_NOT_EXPORTED,
            )
            activity.registerReceiver(
                hotplugReceiver,
                hotplugFilter,
                Context.RECEIVER_NOT_EXPORTED,
            )
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(permissionReceiver, permissionFilter)
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(hotplugReceiver, hotplugFilter)
        }
    }

    fun unregister() {
        try {
            activity.unregisterReceiver(permissionReceiver)
        } catch (_: Exception) {
        }
        try {
            activity.unregisterReceiver(hotplugReceiver)
        } catch (_: Exception) {
        }
        close()
        eventSink = null
    }

    fun status(): Map<String, Any?> {
        val sony = findSonyUsbDevices()
        val hasPermission = sony.isNotEmpty() && sony.all { usbManager.hasPermission(it) }
        return mapOf(
            "attached" to sony.isNotEmpty(),
            "hasPermission" to hasPermission,
            "deviceCount" to sony.size,
            "mode" to detectMode(sony),
        )
    }

    fun requestPermission(result: MethodChannel.Result) {
        val devices = findSonyUsbDevices()
        if (devices.isEmpty()) {
            result.success(
                mapOf("ok" to false, "attached" to false, "hasPermission" to false),
            )
            return
        }
        val needing = devices.filter { !usbManager.hasPermission(it) }
        if (needing.isEmpty()) {
            result.success(
                mapOf("ok" to true, "attached" to true, "hasPermission" to true),
            )
            return
        }
        if (permissionResult != null) {
            result.error("busy", "A USB permission prompt is already open.", null)
            return
        }
        permissionResult = result
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val pi = PendingIntent.getBroadcast(
            activity,
            0,
            Intent(ACTION_USB_PERMISSION).setPackage(activity.packageName),
            flags,
        )
        usbManager.requestPermission(needing.first(), pi)
    }

    /**
     * Returns `{ cards: [...], backend, detail, mode }` so the UI can explain
     * an empty result instead of a generic "no photo cards".
     */
    fun listCards(): Map<String, Any?> {
        close()
        val sony = findSonyUsbDevices()
        val mode = detectMode(sony)
        Log.i(TAG, "listCards: devices=${sony.size} mode=$mode")
        if (sony.isEmpty()) {
            return mapOf(
                "cards" to emptyList<Map<String, Any?>>(),
                "backend" to "none",
                "mode" to mode,
                "detail" to "No Sony USB device. Set USB Connection to Mass Storage or MTP, then replug.",
            )
        }
        if (sony.any { !usbManager.hasPermission(it) }) {
            throw SecurityException("USB permission not granted")
        }

        // Give the kernel a moment after attach — claiming too early fails on
        // several OEMs (and on libaums itself; see magnusja/libaums#384).
        try {
            Thread.sleep(1200)
        } catch (_: InterruptedException) {
        }

        val libaumsNotes = mutableListOf<String>()
        val fromLibaums = tryOpenLibaums(libaumsNotes)
        if (fromLibaums.isNotEmpty()) {
            openVolumes = fromLibaums
            Log.i(TAG, "opened ${fromLibaums.size} card(s) via libaums")
            return mapOf(
                "cards" to summarize(fromLibaums),
                "backend" to "libaums",
                "mode" to mode,
                "detail" to null,
            )
        }

        // Mounts / MediaStore often appear a few seconds after plug-in on OEMs
        // like Vivo — retry instead of failing on the first empty scan.
        val mountNotes = mutableListOf<String>()
        val mediaNotes = mutableListOf<String>()
        repeat(5) { attempt ->
            if (attempt > 0) {
                Log.i(TAG, "retry mount/mediastore scan #${attempt + 1}")
                try {
                    Thread.sleep(1600)
                } catch (_: InterruptedException) {
                }
            }
            mountNotes.clear()
            val fromMounted = tryOpenMountedVolumes(mountNotes)
            if (fromMounted.isNotEmpty()) {
                openVolumes = fromMounted
                Log.i(TAG, "opened ${fromMounted.size} card(s) via mounted volumes")
                return mapOf(
                    "cards" to summarize(fromMounted),
                    "backend" to "mounted",
                    "mode" to mode,
                    "detail" to null,
                )
            }
            mediaNotes.clear()
            val fromMedia = tryOpenMediaStoreVolumes(mediaNotes)
            if (fromMedia.isNotEmpty()) {
                openVolumes = fromMedia
                Log.i(TAG, "opened ${fromMedia.size} card(s) via MediaStore")
                return mapOf(
                    "cards" to summarize(fromMedia),
                    "backend" to "mediastore",
                    "mode" to mode,
                    "detail" to null,
                )
            }
        }

        // Most phones (including many vivo builds) keep Sony in MTP even when
        // the camera menu says Mass Storage / Auto. MTP at least reaches Slot 1.
        val mtpNotes = mutableListOf<String>()
        val fromMtp = tryOpenMtp(sony, mtpNotes)
        if (fromMtp.isNotEmpty()) {
            openVolumes = fromMtp
            Log.i(TAG, "opened ${fromMtp.size} card(s) via MTP")
            return mapOf(
                "cards" to summarize(fromMtp),
                "backend" to "mtp",
                "mode" to mode,
                "detail" to if (fromMtp.size == 1) {
                    "Using MTP (Slot 1). For both SD cards: camera USB Connection → " +
                        "Mass Storage, USB LUN → Multi, then unplug/replug."
                } else {
                    null
                },
            )
        }

        val detail = buildString {
            append("Camera is on USB ($mode), but no readable photo card was found. ")
            when (mode) {
                "mtp" -> append(
                    "Phone is talking MTP. That is OK for Slot 1 — if MTP also " +
                        "failed, unplug/replug and Allow USB again. For both cards, " +
                        "set camera USB Connection → Mass Storage and LUN → Multi. ",
                )
                "msc" -> append(
                    "Phone sees Mass Storage but could not open the volumes " +
                        "(common with exFAT/SDXC on some phones). Wait 10s and Retry, " +
                        "or try USB LUN → Single for Slot 1. ",
                )
                else -> append(
                    "Set camera USB Connection → Mass Storage (or MTP), LUN → Multi, " +
                        "then unplug and plug back in. ",
                )
            }
            if (libaumsNotes.isNotEmpty()) append("libaums: ${libaumsNotes.joinToString("; ")}. ")
            if (mountNotes.isNotEmpty()) append("mounts: ${mountNotes.joinToString("; ")}. ")
            if (mediaNotes.isNotEmpty()) append("mediastore: ${mediaNotes.joinToString("; ")}. ")
            if (mtpNotes.isNotEmpty()) append("mtp: ${mtpNotes.joinToString("; ")}.")
        }
        Log.w(TAG, detail)
        return mapOf(
            "cards" to emptyList<Map<String, Any?>>(),
            "backend" to "none",
            "mode" to mode,
            "detail" to detail,
        )
    }

    fun listJpegs(cardId: Int): List<Map<String, Any?>> {
        val volume = openVolumes.getOrNull(cardId)
            ?: throw IllegalStateException("card $cardId is not open — call listCards first")
        val found = mutableListOf<JpegEntry>()
        when (volume) {
            is OpenVolume.Libaums -> walkJpegsUsb(volume.root, "", found)
            is OpenVolume.Mounted -> walkJpegsFile(volume.rootDir, "", found)
            is OpenVolume.Media -> walkJpegsMedia(volume.volumeName, found)
            is OpenVolume.Mtp -> walkJpegsMtp(volume.storageId, found)
        }
        found.sortByDescending { it.modifiedMs }
        return found.map { entry ->
            mapOf(
                "path" to entry.path,
                "name" to entry.name,
                "byteSize" to entry.byteSize,
                "modifiedMs" to entry.modifiedMs,
                "folder" to entry.folder,
            )
        }
    }

    fun copyJpeg(
        cardId: Int,
        usbPath: String,
        destPath: String,
        onProgress: (Long, Long) -> Unit,
    ) {
        val volume = openVolumes.getOrNull(cardId)
            ?: throw IllegalStateException("card $cardId is not open")
        when (volume) {
            is OpenVolume.Libaums -> copyFromUsb(volume, usbPath, destPath, onProgress)
            is OpenVolume.Mounted -> copyFromFile(volume, usbPath, destPath, onProgress)
            is OpenVolume.Media -> copyFromMedia(volume, usbPath, destPath, onProgress)
            is OpenVolume.Mtp -> copyFromMtp(usbPath, destPath, onProgress)
        }
    }

    /**
     * Small JPEG bytes for a grid tile. Prefers the embedded EXIF thumbnail or
     * MediaStore's own thumb so a 20MB original is never fully decoded.
     */
    fun loadThumb(cardId: Int, usbPath: String, maxEdge: Int = 256): ByteArray {
        val volume = openVolumes.getOrNull(cardId)
            ?: throw IllegalStateException("card $cardId is not open")
        val edge = maxEdge.coerceIn(64, 512)
        return when (volume) {
            is OpenVolume.Media -> thumbFromMedia(usbPath, edge)
            is OpenVolume.Mounted -> thumbFromFile(File(volume.rootDir, usbPath), edge)
            is OpenVolume.Libaums -> {
                val file = resolvePathUsb(volume.root, usbPath)
                    ?: throw IllegalArgumentException("missing $usbPath")
                thumbFromUsbFile(file, edge)
            }
            is OpenVolume.Mtp -> thumbFromMtp(usbPath, edge)
        }
    }

    fun close() {
        for (volume in openVolumes) {
            if (volume is OpenVolume.Libaums) {
                try {
                    volume.device.close()
                } catch (e: Exception) {
                    Log.w(TAG, "close failed", e)
                }
            }
        }
        openVolumes = emptyList()
        // MtpDevice.close() also closes the UsbDeviceConnection.
        closeMtpOnly()
    }

    private fun tryOpenLibaums(notes: MutableList<String>): List<OpenVolume> {
        val massDevices = try {
            UsbMassStorageDevice.getMassStorageDevices(activity)
                .filter { it.usbDevice.vendorId == SONY_VENDOR_ID }
        } catch (e: Exception) {
            notes.add("enumerate failed: ${e.message}")
            return emptyList()
        }
        if (massDevices.isEmpty()) {
            notes.add("no MSC interfaces for libaums (phone may have claimed them)")
            return emptyList()
        }

        val opened = mutableListOf<OpenVolume>()
        for ((i, mass) in massDevices.withIndex()) {
            try {
                mass.init()
                val partitions = mass.partitions
                if (partitions.isEmpty()) {
                    notes.add("LUN$i: no partitions (often exFAT — needs phone mount)")
                    mass.close()
                    continue
                }
                val root = partitions[0].fileSystem.rootDirectory
                val counts = countMediaUsb(root)
                val hasDcim = hasDcimUsb(root)
                // Keep PMHOME out; keep anything that looks like a photo card,
                // even if currently empty, so the user can still pick the slot.
                val looksLikePmHome =
                    !hasDcim && counts.jpeg == 0 && counts.raw == 0 &&
                        root.listFiles()?.none { it.isDirectory } != false
                if (looksLikePmHome) {
                    notes.add("LUN$i: skipped PMHOME-like volume")
                    mass.close()
                    continue
                }
                opened.add(
                    OpenVolume.Libaums(
                        mass,
                        root,
                        "Card ${opened.size + 1}",
                    ),
                )
            } catch (e: Exception) {
                notes.add("LUN$i: ${e.javaClass.simpleName}: ${e.message}")
                Log.w(TAG, "libaums open failed", e)
                try {
                    mass.close()
                } catch (_: Exception) {
                }
            }
        }
        return opened
    }

    private fun tryOpenMountedVolumes(notes: MutableList<String>): List<OpenVolume> {
        val candidates = linkedMapOf<String, File>()

        // Primary: StorageManager volumes (Android 7+), directory on API 30+.
        try {
            val sm = activity.getSystemService(StorageManager::class.java)
            for (volume in sm.storageVolumes) {
                if (volume.isPrimary) continue
                val state = volume.state
                if (state != null &&
                    state != Environment.MEDIA_MOUNTED &&
                    state != Environment.MEDIA_MOUNTED_READ_ONLY
                ) {
                    continue
                }
                val dir: File? = if (Build.VERSION.SDK_INT >= 30) {
                    volume.directory
                } else {
                    @Suppress("DEPRECATION")
                    volume.javaClass.methods
                        .firstOrNull { it.name == "getPathFile" && it.parameterTypes.isEmpty() }
                        ?.invoke(volume) as? File
                        ?: volume.javaClass.methods
                            .firstOrNull { it.name == "getPath" && it.parameterTypes.isEmpty() }
                            ?.invoke(volume)
                            ?.let { File(it.toString()) }
                }
                if (dir == null) {
                    notes.add("${volume.getDescription(activity)}: no path")
                    continue
                }
                if (!dir.exists() || !dir.canRead()) {
                    notes.add("${dir.path}: unreadable")
                    continue
                }
                if (dir.name.contains("PMHOME", ignoreCase = true)) continue
                if (!hasDcimFile(dir) && countMediaFile(dir).let { it.jpeg + it.raw } == 0) {
                    // Not a photo card — skip things like USB sticks of docs.
                    // Still record it so diagnostics show we saw the mount.
                    notes.add("${dir.path}: mounted, no DCIM/media")
                    continue
                }
                candidates[dir.absolutePath] = dir
            }
        } catch (e: Exception) {
            notes.add("StorageManager: ${e.message}")
            Log.w(TAG, "StorageManager scan failed", e)
        }

        // Secondary: scan /storage for newly appeared UUID-like volumes.
        try {
            val storageRoot = File("/storage")
            storageRoot.listFiles()?.forEach { entry ->
                if (!entry.isDirectory) return@forEach
                val name = entry.name
                if (name == "emulated" || name == "self" || name.startsWith(".")) return@forEach
                if (name.contains("PMHOME", ignoreCase = true)) return@forEach
                if (!entry.canRead()) return@forEach
                if (!hasDcimFile(entry) &&
                    countMediaFile(entry).let { it.jpeg + it.raw } == 0
                ) {
                    return@forEach
                }
                candidates.putIfAbsent(entry.absolutePath, entry)
            }
        } catch (e: Exception) {
            notes.add("/storage scan: ${e.message}")
        }

        if (candidates.isEmpty()) {
            if (notes.none { it.contains("no DCIM") || it.contains("unreadable") }) {
                notes.add("no removable volumes mounted yet")
            }
            return emptyList()
        }

        return candidates.values.mapIndexed { index, dir ->
            OpenVolume.Mounted(dir, dir.name.ifEmpty { "Card ${index + 1}" })
        }
    }

    private fun tryOpenMediaStoreVolumes(notes: MutableList<String>): List<OpenVolume> {
        if (Build.VERSION.SDK_INT < 29) {
            notes.add("MediaStore volumes need API 29+")
            return emptyList()
        }
        val names = try {
            MediaStore.getExternalVolumeNames(activity)
        } catch (e: Exception) {
            notes.add("getExternalVolumeNames: ${e.message}")
            return emptyList()
        }
        val opened = mutableListOf<OpenVolume>()
        for (name in names) {
            if (name == MediaStore.VOLUME_EXTERNAL_PRIMARY) continue
            if (name.contains("pmhome", ignoreCase = true)) continue
            val counts = countMediaStore(name)
            if (counts.jpeg + counts.raw == 0) {
                notes.add("$name: no images indexed yet")
                continue
            }
            opened.add(OpenVolume.Media(name, name))
        }
        if (opened.isEmpty() && notes.isEmpty()) {
            notes.add("no secondary MediaStore volumes")
        }
        return opened
    }

    private fun summarize(volumes: List<OpenVolume>): List<Map<String, Any?>> {
        val cards = volumes.mapIndexed { index, volume ->
            val counts = when (volume) {
                is OpenVolume.Libaums -> countMediaUsb(volume.root)
                is OpenVolume.Mounted -> countMediaFile(volume.rootDir)
                is OpenVolume.Media -> countMediaStore(volume.volumeName)
                is OpenVolume.Mtp -> countMediaMtp(volume.storageId)
            }
            val hasDcim = when (volume) {
                is OpenVolume.Libaums -> hasDcimUsb(volume.root)
                is OpenVolume.Mounted -> hasDcimFile(volume.rootDir)
                is OpenVolume.Media -> counts.jpeg + counts.raw > 0
                is OpenVolume.Mtp -> counts.jpeg + counts.raw > 0
            }
            mutableMapOf<String, Any?>(
                "id" to index,
                "label" to cardLabel(index, counts, volume.labelHint),
                "jpegCount" to counts.jpeg,
                "rawCount" to counts.raw,
                "hasDcim" to hasDcim,
                "suggested" to false,
            )
        }

        val best = cards.indices.maxWithOrNull(
            compareBy<Int> { cards[it]["jpegCount"] as Int }
                .thenBy { -(cards[it]["rawCount"] as Int) },
        )
        if (best != null && (cards[best]["jpegCount"] as Int) > 0) {
            cards[best]["suggested"] = true
        }
        return cards
    }

    private fun copyFromUsb(
        volume: OpenVolume.Libaums,
        usbPath: String,
        destPath: String,
        onProgress: (Long, Long) -> Unit,
    ) {
        val file = resolvePathUsb(volume.root, usbPath)
            ?: throw IllegalArgumentException("missing $usbPath")
        if (file.isDirectory) throw IllegalArgumentException("$usbPath is a directory")

        val dest = File(destPath)
        dest.parentFile?.mkdirs()
        val total = file.length
        onProgress(0L, total)

        val partial = File("$destPath.part")
        try {
            val fs = volume.device.partitions[0].fileSystem
            UsbFileStreamFactory.createBufferedInputStream(file, fs).use { input ->
                FileOutputStream(partial).use { output ->
                    val buffer = ByteArray(fs.chunkSize.coerceAtLeast(16 * 1024))
                    var received = 0L
                    while (true) {
                        val n = input.read(buffer)
                        if (n <= 0) break
                        output.write(buffer, 0, n)
                        received += n
                        onProgress(received, total)
                    }
                }
            }
            finalizePartial(partial, dest, file.lastModified())
            onProgress(total, total)
        } catch (e: Exception) {
            partial.delete()
            throw e
        }
    }

    private fun copyFromFile(
        volume: OpenVolume.Mounted,
        relativePath: String,
        destPath: String,
        onProgress: (Long, Long) -> Unit,
    ) {
        val source = File(volume.rootDir, relativePath)
        if (!source.isFile) throw IllegalArgumentException("missing $relativePath")

        val dest = File(destPath)
        dest.parentFile?.mkdirs()
        val total = source.length()
        onProgress(0L, total)

        val partial = File("$destPath.part")
        try {
            FileInputStream(source).use { input ->
                FileOutputStream(partial).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var received = 0L
                    while (true) {
                        val n = input.read(buffer)
                        if (n <= 0) break
                        output.write(buffer, 0, n)
                        received += n
                        onProgress(received, total)
                    }
                }
            }
            finalizePartial(partial, dest, source.lastModified())
            onProgress(total, total)
        } catch (e: Exception) {
            partial.delete()
            throw e
        }
    }

    private fun finalizePartial(partial: File, dest: File, modifiedMs: Long) {
        if (!partial.exists()) return
        if (dest.exists()) dest.delete()
        if (!partial.renameTo(dest)) {
            partial.copyTo(dest, overwrite = true)
            partial.delete()
        }
        if (modifiedMs > 0) dest.setLastModified(modifiedMs)
    }

    private fun emit(event: String) {
        activity.runOnUiThread {
            eventSink?.success(mapOf("event" to event))
        }
    }

    private fun hasSonyMassStorage(): Boolean = findSonyUsbDevices().isNotEmpty()

    /** Any Sony USB device — MSC preferred, but MTP still counts as "attached". */
    private fun findSonyUsbDevices(): List<UsbDevice> =
        usbManager.deviceList.values.filter { it.vendorId == SONY_VENDOR_ID }

    private fun detectMode(devices: List<UsbDevice>): String {
        var msc = false
        var mtp = false
        for (device in devices) {
            for (i in 0 until device.interfaceCount) {
                when (device.getInterface(i).interfaceClass) {
                    UsbConstants.USB_CLASS_MASS_STORAGE -> msc = true
                    UsbConstants.USB_CLASS_STILL_IMAGE -> mtp = true
                }
            }
        }
        return when {
            msc && mtp -> "both"
            msc -> "msc"
            mtp -> "mtp"
            devices.isNotEmpty() -> "unknown"
            else -> "none"
        }
    }

    private fun tryOpenMtp(
        devices: List<UsbDevice>,
        notes: MutableList<String>,
    ): List<OpenVolume> {
        closeMtpOnly()
        for (usbDevice in devices) {
            if (!hasMtpInterface(usbDevice)) {
                notes.add("${usbDevice.deviceName}: no MTP interface")
                continue
            }
            if (!usbManager.hasPermission(usbDevice)) {
                notes.add("${usbDevice.deviceName}: no permission")
                continue
            }
            val connection = usbManager.openDevice(usbDevice)
            if (connection == null) {
                notes.add("${usbDevice.deviceName}: openDevice failed")
                continue
            }
            val mtp = MtpDevice(usbDevice)
            if (!mtp.open(connection)) {
                notes.add("${usbDevice.deviceName}: MtpDevice.open failed")
                connection.close()
                continue
            }
            val storageIds = mtp.storageIds
            if (storageIds == null || storageIds.isEmpty()) {
                notes.add("${usbDevice.deviceName}: no MTP storages")
                mtp.close()
                connection.close()
                continue
            }
            mtpDevice = mtp
            mtpConnection = connection
            val opened = mutableListOf<OpenVolume>()
            for ((index, storageId) in storageIds.withIndex()) {
                val info = mtp.getStorageInfo(storageId)
                val description = info?.volumeIdentifier?.takeIf { it.isNotBlank() }
                    ?: info?.description?.takeIf { it.isNotBlank() }
                    ?: "Slot ${index + 1}"
                opened.add(
                    OpenVolume.Mtp(
                        storageId = storageId,
                        labelHint = "$description · MTP",
                    ),
                )
                val counts = countMediaMtp(storageId)
                Log.i(
                    TAG,
                    "MTP storage $storageId ($description): " +
                        "${counts.jpeg} jpg / ${counts.raw} raw",
                )
            }
            // Prefer storages that actually have media; drop pure-empty shells
            // only when at least one storage has files.
            val withMedia = opened.filter {
                val c = countMediaMtp((it as OpenVolume.Mtp).storageId)
                c.jpeg + c.raw > 0
            }
            return withMedia.ifEmpty { opened }
        }
        return emptyList()
    }

    private fun closeMtpOnly() {
        val device = mtpDevice
        mtpDevice = null
        mtpConnection = null
        if (device == null) return
        try {
            device.close()
        } catch (_: Exception) {
        }
    }

    private fun hasMtpInterface(device: UsbDevice): Boolean {
        for (i in 0 until device.interfaceCount) {
            if (device.getInterface(i).interfaceClass ==
                UsbConstants.USB_CLASS_STILL_IMAGE
            ) {
                return true
            }
        }
        return false
    }

    private fun countMediaMtp(storageId: Int): MediaCounts {
        val mtp = mtpDevice ?: return MediaCounts(0, 0)
        var jpeg = 0
        var raw = 0
        // Parent -1 (0xFFFFFFFF) = every object in this storage.
        val handles = mtp.getObjectHandles(storageId, 0, -1)
            ?: return MediaCounts(0, 0)
        for (handle in handles) {
            val info = mtp.getObjectInfo(handle) ?: continue
            when (extensionOf(info.name ?: "")) {
                "jpg", "jpeg" -> jpeg++
                "arw" -> raw++
            }
        }
        return MediaCounts(jpeg, raw)
    }

    private fun walkJpegsMtp(storageId: Int, out: MutableList<JpegEntry>) {
        val mtp = mtpDevice ?: return
        // Parent -1 (0xFFFFFFFF) = every object in this storage.
        val handles = mtp.getObjectHandles(storageId, 0, -1) ?: return
        for (handle in handles) {
            val info = mtp.getObjectInfo(handle) ?: continue
            val name = info.name ?: continue
            if (extensionOf(name) !in setOf("jpg", "jpeg")) continue
            // Skip association/folder objects that happen to have a name.
            if (info.format == MtpConstants.FORMAT_ASSOCIATION) continue
            // dateCreated / dateModified are already epoch milliseconds.
            val modifiedMs = when {
                info.dateCreated > 0L -> info.dateCreated
                info.dateModified > 0L -> info.dateModified
                else -> 0L
            }
            out.add(
                JpegEntry(
                    path = handle.toString(),
                    name = name,
                    folder = "MTP",
                    byteSize = info.compressedSize.toLong(),
                    modifiedMs = modifiedMs,
                ),
            )
        }
    }

    private fun copyFromMtp(
        handlePath: String,
        destPath: String,
        onProgress: (Long, Long) -> Unit,
    ) {
        val mtp = mtpDevice ?: throw IllegalStateException("MTP not open")
        val handle = handlePath.toIntOrNull()
            ?: throw IllegalArgumentException("bad MTP handle $handlePath")
        val info = mtp.getObjectInfo(handle)
        val total = info?.compressedSize?.toLong() ?: 0L
        onProgress(0L, total)

        val dest = File(destPath)
        dest.parentFile?.mkdirs()
        val partial = File("$destPath.part")
        if (partial.exists()) partial.delete()

        val ok = mtp.importFile(handle, partial.absolutePath)
        if (!ok || !partial.exists() || partial.length() <= 0L) {
            partial.delete()
            throw IllegalStateException("MTP importFile failed for $handle")
        }
        val modifiedMs = when {
            info != null && info.dateCreated > 0L -> info.dateCreated
            info != null && info.dateModified > 0L -> info.dateModified
            else -> 0L
        }
        finalizePartial(partial, dest, modifiedMs)
        val written = dest.length()
        onProgress(if (total > 0) total else written, if (total > 0) total else written)
    }

    @Suppress("UNUSED_PARAMETER")
    private fun thumbFromMtp(handlePath: String, maxEdge: Int): ByteArray {
        val mtp = mtpDevice ?: throw IllegalStateException("MTP not open")
        val handle = handlePath.toIntOrNull()
            ?: throw IllegalArgumentException("bad MTP handle $handlePath")
        val thumb = mtp.getThumbnail(handle)
        if (thumb != null && thumb.isNotEmpty()) return thumb
        // No device thumb — importing a full JPEG just for the grid is too heavy.
        throw IllegalStateException("no MTP thumbnail for $handle")
    }

    private data class MediaCounts(val jpeg: Int, val raw: Int)

    private data class JpegEntry(
        val path: String,
        val name: String,
        val folder: String,
        val byteSize: Long,
        val modifiedMs: Long,
    )

    private fun hasDcimUsb(root: UsbFile): Boolean =
        root.listFiles()?.any { it.isDirectory && it.name.equals("DCIM", true) } == true

    private fun hasDcimFile(root: File): Boolean =
        File(root, "DCIM").isDirectory || File(root, "dcim").isDirectory

    private fun countMediaUsb(root: UsbFile): MediaCounts {
        var jpeg = 0
        var raw = 0
        val stack = ArrayDeque<UsbFile>()
        stack.add(root)
        var visited = 0
        while (stack.isNotEmpty() && visited < 5000) {
            val dir = stack.removeFirst()
            visited++
            val children = try {
                dir.listFiles()
            } catch (_: Exception) {
                null
            } ?: continue
            for (child in children) {
                if (child.isDirectory) {
                    if (child.name.equals("PRIVATE", true)) continue
                    stack.add(child)
                } else {
                    when (extensionOf(child.name)) {
                        "jpg", "jpeg" -> jpeg++
                        "arw" -> raw++
                    }
                }
            }
        }
        return MediaCounts(jpeg, raw)
    }

    private fun countMediaFile(root: File): MediaCounts {
        var jpeg = 0
        var raw = 0
        val stack = ArrayDeque<File>()
        stack.add(root)
        var visited = 0
        while (stack.isNotEmpty() && visited < 5000) {
            val dir = stack.removeFirst()
            visited++
            val children = dir.listFiles() ?: continue
            for (child in children) {
                if (child.isDirectory) {
                    if (child.name.equals("PRIVATE", true)) continue
                    stack.add(child)
                } else {
                    when (extensionOf(child.name)) {
                        "jpg", "jpeg" -> jpeg++
                        "arw" -> raw++
                    }
                }
            }
        }
        return MediaCounts(jpeg, raw)
    }

    private fun walkJpegsUsb(dir: UsbFile, prefix: String, out: MutableList<JpegEntry>) {
        val children = try {
            dir.listFiles()
        } catch (_: Exception) {
            null
        } ?: return
        for (child in children) {
            val path = if (prefix.isEmpty()) child.name else "$prefix/${child.name}"
            if (child.isDirectory) {
                if (child.name.equals("PRIVATE", true)) continue
                walkJpegsUsb(child, path, out)
            } else if (extensionOf(child.name) in setOf("jpg", "jpeg")) {
                val folder = prefix.substringAfter("DCIM/", prefix).ifEmpty { "DCIM" }
                out.add(
                    JpegEntry(
                        path = path,
                        name = child.name,
                        folder = folder,
                        byteSize = child.length,
                        modifiedMs = child.lastModified(),
                    ),
                )
            }
        }
    }

    private fun walkJpegsFile(dir: File, prefix: String, out: MutableList<JpegEntry>) {
        val children = dir.listFiles() ?: return
        for (child in children) {
            val path = if (prefix.isEmpty()) child.name else "$prefix/${child.name}"
            if (child.isDirectory) {
                if (child.name.equals("PRIVATE", true)) continue
                walkJpegsFile(child, path, out)
            } else if (extensionOf(child.name) in setOf("jpg", "jpeg")) {
                val folder = prefix.substringAfter("DCIM/", prefix).ifEmpty { "DCIM" }
                out.add(
                    JpegEntry(
                        path = path,
                        name = child.name,
                        folder = folder,
                        byteSize = child.length(),
                        modifiedMs = child.lastModified(),
                    ),
                )
            }
        }
    }

    private fun resolvePathUsb(root: UsbFile, path: String): UsbFile? {
        var current: UsbFile = root
        for (segment in path.split('/').filter { it.isNotEmpty() }) {
            val next = current.listFiles()?.firstOrNull { it.name == segment } ?: return null
            current = next
        }
        return current
    }

    private fun countMediaStore(volumeName: String): MediaCounts {
        var jpeg = 0
        var raw = 0
        val images = MediaStore.Images.Media.getContentUri(volumeName)
        activity.contentResolver.query(
            images,
            arrayOf(MediaStore.Images.Media.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val nameIdx = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
            while (cursor.moveToNext()) {
                when (extensionOf(cursor.getString(nameIdx) ?: "")) {
                    "jpg", "jpeg" -> jpeg++
                    "arw" -> raw++
                }
            }
        }
        // ARW is often not in Images — also check Files.
        if (Build.VERSION.SDK_INT >= 29) {
            val files = MediaStore.Files.getContentUri(volumeName)
            activity.contentResolver.query(
                files,
                arrayOf(MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.MIME_TYPE),
                "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ? OR ${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ?",
                arrayOf("%.ARW", "%.arw"),
                null,
            )?.use { cursor ->
                raw = cursor.count
            }
        }
        return MediaCounts(jpeg, raw)
    }

    private fun walkJpegsMedia(volumeName: String, out: MutableList<JpegEntry>) {
        val images = MediaStore.Images.Media.getContentUri(volumeName)
        activity.contentResolver.query(
            images,
            arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.SIZE,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_MODIFIED,
                MediaStore.Images.Media.RELATIVE_PATH,
            ),
            null,
            null,
            "${MediaStore.Images.Media.DATE_TAKEN} DESC",
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val nameIdx = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
            val sizeIdx = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
            val takenIdx = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN)
            val modIdx = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
            val pathIdx = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.RELATIVE_PATH)
            while (cursor.moveToNext()) {
                val name = cursor.getString(nameIdx) ?: continue
                if (extensionOf(name) !in setOf("jpg", "jpeg")) continue
                val id = cursor.getLong(idIdx)
                val uri = Uri.withAppendedPath(images, id.toString()).toString()
                val taken = cursor.getLong(takenIdx)
                val modifiedSec = cursor.getLong(modIdx)
                val modifiedMs = when {
                    taken > 0L -> taken
                    modifiedSec > 0L -> modifiedSec * 1000L
                    else -> 0L
                }
                val relative = cursor.getString(pathIdx) ?: "DCIM/"
                out.add(
                    JpegEntry(
                        path = uri,
                        name = name,
                        folder = relative.trimEnd('/'),
                        byteSize = cursor.getLong(sizeIdx),
                        modifiedMs = modifiedMs,
                    ),
                )
            }
        }
    }

    private fun thumbFromMedia(uriString: String, maxEdge: Int): ByteArray {
        val uri = Uri.parse(uriString)
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                val bitmap = activity.contentResolver.loadThumbnail(
                    uri,
                    Size(maxEdge, maxEdge),
                    null,
                )
                return jpegBytes(bitmap, quality = 80)
            } catch (e: Exception) {
                Log.w(TAG, "loadThumbnail failed, falling back to EXIF", e)
            }
        }
        activity.contentResolver.openInputStream(uri)?.use { input ->
            exifThumb(input)?.let { return it }
        }
        activity.contentResolver.openInputStream(uri)?.use { input ->
            return sampleJpeg(input.readBytes(), maxEdge)
        }
        throw IllegalStateException("thumb failed for $uriString")
    }

    private fun thumbFromFile(file: File, maxEdge: Int): ByteArray {
        if (!file.isFile) throw IllegalArgumentException("missing ${file.path}")
        try {
            ExifInterface(file.absolutePath).thumbnail?.let { return it }
        } catch (_: Exception) {
        }
        return sampleJpeg(file.readBytes(), maxEdge)
    }

    private fun thumbFromUsbFile(file: UsbFile, maxEdge: Int): ByteArray {
        // Read only the head first — Sony EXIF thumbs live in the first tens of KB.
        val headSize = minOf(file.length, 256 * 1024L).toInt()
        val head = ByteArray(headSize)
        var headRead = 0
        UsbFileInputStream(file).use { input ->
            while (headRead < headSize) {
                val n = input.read(head, headRead, headSize - headRead)
                if (n <= 0) break
                headRead += n
            }
        }
        exifThumb(ByteArrayInputStream(head, 0, headRead))?.let { return it }

        // No embedded thumb — sample-decode. Cap how much we pull for a grid cell.
        val limit = minOf(file.length, 2L * 1024 * 1024).toInt()
        if (limit <= headRead) return sampleJpeg(head.copyOf(headRead), maxEdge)
        val bytes = ByteArray(limit)
        UsbFileInputStream(file).use { input ->
            var offset = 0
            while (offset < limit) {
                val n = input.read(bytes, offset, limit - offset)
                if (n <= 0) break
                offset += n
            }
        }
        return sampleJpeg(bytes, maxEdge)
    }

    private fun exifThumb(input: java.io.InputStream): ByteArray? =
        try {
            ExifInterface(input).thumbnail
        } catch (_: Exception) {
            null
        }

    private fun sampleJpeg(bytes: ByteArray, maxEdge: Int): ByteArray {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        val w = bounds.outWidth
        val h = bounds.outHeight
        while (w / sample > maxEdge * 2 || h / sample > maxEdge * 2) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample.coerceAtLeast(1) }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
            ?: throw IllegalStateException("decode failed")
        return jpegBytes(bitmap, quality = 80)
    }

    private fun jpegBytes(bitmap: Bitmap, quality: Int): ByteArray {
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        if (!bitmap.isRecycled) bitmap.recycle()
        return out.toByteArray()
    }

    private fun copyFromMedia(
        @Suppress("UNUSED_PARAMETER") volume: OpenVolume.Media,
        uriString: String,
        destPath: String,
        onProgress: (Long, Long) -> Unit,
    ) {
        val uri = Uri.parse(uriString)
        val dest = File(destPath)
        dest.parentFile?.mkdirs()
        val partial = File("$destPath.part")

        val total = activity.contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getLong(0) else 0L
        } ?: 0L
        onProgress(0L, total)

        try {
            activity.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(partial).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var received = 0L
                    while (true) {
                        val n = input.read(buffer)
                        if (n <= 0) break
                        output.write(buffer, 0, n)
                        received += n
                        onProgress(received, if (total > 0) total else received)
                    }
                }
            } ?: throw IllegalStateException("openInputStream failed for $uriString")
            finalizePartial(partial, dest, 0L)
            onProgress(if (total > 0) total else dest.length(), if (total > 0) total else dest.length())
        } catch (e: Exception) {
            partial.delete()
            throw e
        }
    }

    private fun cardLabel(index: Int, counts: MediaCounts, hint: String): String {
        val slot = "Card ${index + 1}"
        val kind = when {
            counts.jpeg > 0 && counts.raw == 0 -> "JPEG"
            counts.raw > 0 && counts.jpeg == 0 -> "RAW"
            counts.jpeg > 0 && counts.raw > 0 -> "mixed"
            else -> null
        }
        return if (kind == null) {
            if (hint.isNotBlank() && hint != slot) "$slot · $hint" else slot
        } else {
            "$slot · $kind"
        }
    }

    private fun extensionOf(name: String): String =
        name.substringAfterLast('.', "").lowercase(Locale.US)

    companion object {
        private const val TAG = "SonyTransferUsb"
        private const val ACTION_USB_PERMISSION = "com.winston.sony_transfer.USB_PERMISSION"
        const val SONY_VENDOR_ID = 0x054C
    }
}
