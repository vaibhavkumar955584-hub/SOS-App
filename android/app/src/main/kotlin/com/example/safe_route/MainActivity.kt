package com.example.safe_route

import com.example.safe_route.BuildConfig
import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.ContentValues
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Environment
import android.os.Build
import android.os.BatteryManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.media.MediaScannerConnection
import android.provider.MediaStore
import android.view.WindowManager
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import android.net.Uri
import android.telephony.TelephonyManager
import android.telephony.PhoneStateListener
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.LocationSettingsRequest
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.Priority
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingClient
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.common.api.ResolvableApiException
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayList
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val smsChannelName = "safe_route/sms"
    private val geofenceChannelName = "safe_route/geofence"
    private val shortcutChannelName = "safe_route/shortcut"
    private var shortcutChannel: MethodChannel? = null
    private var pendingTriggerSource: String? = null

    private lateinit var geofencingClient: GeofencingClient
    private var geofencePendingIntent: PendingIntent? = null
    private var pendingContactPickerResult: MethodChannel.Result? = null
    private val REQUEST_CODE_PICK_CONTACT = 1002
    private var pendingImagePickerResult: MethodChannel.Result? = null
    private val REQUEST_CODE_PICK_IMAGE = 1003

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        registerDynamicShortcuts()
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(KEYGUARD_SERVICE) as android.app.KeyguardManager
            keyguardManager.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
    }

    private fun registerDynamicShortcuts() {
        try {
            val sosIntent = Intent(this, SosShortcutActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("triggerSource", "shortcut")
            }

            val sosShortcut = ShortcutInfoCompat.Builder(this, "sos_trigger_shortcut")
                .setShortLabel("Emergency SOS")
                .setLongLabel("Trigger Emergency SOS (2s Hold)")
                .setIcon(IconCompat.createWithResource(this, R.drawable.sos_widget_circle))
                .setIntent(sosIntent)
                .build()

            ShortcutManagerCompat.setDynamicShortcuts(this, listOf(sosShortcut))
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == "ACTION_TRIGGER_SOS") {
            val source = intent.getStringExtra("triggerSource") ?: "widget"
            pendingTriggerSource = source
            shortcutChannel?.invokeMethod("triggerSos", mapOf("source" to source))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, shortcutChannelName)
        shortcutChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingTriggerSource" -> {
                    val src = pendingTriggerSource
                    pendingTriggerSource = null
                    result.success(src)
                }
                else -> result.notImplemented()
            }
        }

        handleIntent(intent)

        geofencingClient = LocationServices.getGeofencingClient(this)

        val geofenceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, geofenceChannelName)

        GeofenceBroadcastReceiver.eventListener = { payload ->
            Handler(Looper.getMainLooper()).post {
                geofenceChannel.invokeMethod("onGeofenceEvent", payload)
            }
        }

        geofenceChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "registerGeofences" -> {
                    @Suppress("UNCHECKED_CAST")
                    val zones = call.argument<List<Map<String, Any>>>("zones") ?: emptyList()
                    registerGeofencesNative(zones, result)
                }
                "removeGeofences" -> {
                    val ids = call.argument<List<String>>("ids") ?: emptyList()
                    removeGeofencesNative(ids, result)
                }
                "removeAllGeofences" -> {
                    removeAllGeofencesNative(result)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            smsChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pinSosWidget" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val appWidgetManager = getSystemService(android.appwidget.AppWidgetManager::class.java)
                        val myProvider = android.content.ComponentName(this, SosAppWidgetProvider::class.java)
                        if (appWidgetManager.isRequestPinAppWidgetSupported) {
                            val pinnedWidgetCallbackIntent = Intent(this, MainActivity::class.java)
                            val successCallback = PendingIntent.getActivity(
                                this, 0, pinnedWidgetCallbackIntent,
                                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                            )
                            appWidgetManager.requestPinAppWidget(myProvider, null, successCallback)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }

                "pickImageFromGallery" -> {
                    pickImageFromGallery(result)
                }

                "getPendingProfileImage" -> {
                    val prefs = getSharedPreferences("safe_route_picker", Context.MODE_PRIVATE)
                    val imagePath = prefs.getString("pending_profile_image", null)
                    if (imagePath != null && File(imagePath).exists()) {
                        prefs.edit().remove("pending_profile_image").apply()
                        result.success(mapOf("hasPending" to true, "imagePath" to imagePath))
                    } else {
                        result.success(mapOf("hasPending" to false))
                    }
                }

                "pickContactFromPhonebook" -> {
                    pickContactFromPhonebook(result)
                }

                "getPendingPickedContact" -> {
                    val prefs = getSharedPreferences("safe_route_picker", Context.MODE_PRIVATE)
                    val phone = prefs.getString("pending_phone", null)
                    val name = prefs.getString("pending_name", null)
                    if (phone != null) {
                        prefs.edit().remove("pending_phone").remove("pending_name").apply()
                        result.success(mapOf(
                            "hasPending" to true,
                            "phoneNumber" to phone,
                            "name" to name
                        ))
                    } else {
                        result.success(mapOf("hasPending" to false))
                    }
                }

                "makeDirectCall" -> {
                    val phoneNumber = call.argument<String>("phoneNumber")
                    if (phoneNumber.isNullOrBlank()) {
                        result.success(mapOf("success" to false, "errorMessage" to "Missing phone number."))
                        return@setMethodCallHandler
                    }
                    makeDirectCall(phoneNumber, result)
                }

                "startCallListener" -> {
                    startCallListener(result)
                }

                "resolveLocationSettings" -> {
                    resolveLocationSettings(result)
                }

                "sendDirectSms" -> {
                    val phoneNumber = call.argument<String>("phoneNumber")
                    val message = call.argument<String>("message")
                    val subscriptionId = call.argument<Int>("subscriptionId")

                    if (phoneNumber.isNullOrBlank() || message.isNullOrBlank()) {
                        result.success(
                            mapOf(
                                "success" to false,
                                "errorMessage" to "Missing phone number or message.",
                            ),
                        )
                        return@setMethodCallHandler
                    }

                    sendDirectSms(
                        phoneNumber = phoneNumber,
                        message = message,
                        subscriptionId = subscriptionId,
                        result = result,
                    )
                }

                "getSmsSubscriptions" -> {
                    result.success(getSmsSubscriptions())
                }

                "getBatteryLevel" -> {
                    result.success(getBatteryLevel())
                }

                "saveRecordingToDownloads" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val displayName = call.argument<String>("displayName")
                    if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
                        result.success(
                            mapOf(
                                "success" to false,
                                "errorMessage" to "Missing recording source path or file name.",
                            ),
                        )
                        return@setMethodCallHandler
                    }

                    result.success(saveRecordingToDownloads(sourcePath, displayName))
                }

                "openFile" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.success(
                            mapOf(
                                "success" to false,
                                "errorMessage" to "Missing file path.",
                            ),
                        )
                        return@setMethodCallHandler
                    }

                    result.success(openFile(path))
                }

                "getTelephonyNetworkInfo" -> {
                    result.success(getTelephonyNetworkInfo())
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun sendDirectSms(
        phoneNumber: String,
        message: String,
        subscriptionId: Int?,
        result: MethodChannel.Result,
    ) {
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.SEND_SMS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(
                mapOf(
                    "success" to false,
                    "errorMessage" to "SEND_SMS permission not granted.",
                ),
            )
            return
        }

        val smsManager = getSmsManager(subscriptionId)
        val action = "com.example.safe_route.SMS_SENT.${System.nanoTime()}"
        val pendingIntentFlags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                }
        var completed = false
        var receiver: BroadcastReceiver? = null
        val mainHandler = Handler(Looper.getMainLooper())
        val parts = smsManager.divideMessage(message)
        var pendingPartCount = parts.size.coerceAtLeast(1)
        var firstErrorCode: Int? = null
        var firstErrorMessage: String? = null

        fun finish(payload: Map<String, Any?>) {
            if (completed) {
                return
            }
            completed = true
            mainHandler.removeCallbacksAndMessages(null)
            try {
                if (receiver != null) {
                    unregisterReceiver(receiver)
                }
            } catch (_: Exception) {
            }
            result.success(payload)
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val errorMessage =
                    when (resultCode) {
                        Activity.RESULT_OK -> null
                        SmsManager.RESULT_ERROR_GENERIC_FAILURE ->
                            "Generic SMS failure."
                        SmsManager.RESULT_ERROR_NO_SERVICE ->
                            "No mobile service available."
                        SmsManager.RESULT_ERROR_NULL_PDU ->
                            "SMS payload was invalid."
                        SmsManager.RESULT_ERROR_RADIO_OFF ->
                            "Device radio is off."
                        else -> "Direct SMS failed with code $resultCode."
                    }

                if (resultCode != Activity.RESULT_OK && firstErrorCode == null) {
                    firstErrorCode = resultCode
                    firstErrorMessage = errorMessage
                }

                pendingPartCount -= 1
                if (pendingPartCount <= 0) {
                    finish(
                        mapOf(
                            "success" to (firstErrorCode == null),
                            "errorCode" to firstErrorCode,
                            "errorMessage" to firstErrorMessage,
                        ),
                    )
                }
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, IntentFilter(action), RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, IntentFilter(action))
        }

        mainHandler.postDelayed(
            {
                finish(
                    mapOf(
                        "success" to false,
                        "errorMessage" to "Timed out while waiting for SMS subsystem.",
                    ),
                )
            },
            25000,
        )

        try {
            if (parts.size <= 1) {
                val sentPendingIntent = PendingIntent.getBroadcast(
                    this,
                    action.hashCode(),
                    Intent(action),
                    pendingIntentFlags,
                )
                smsManager.sendTextMessage(phoneNumber, null, message, sentPendingIntent, null)
            } else {
                val sentPendingIntents = ArrayList<PendingIntent>(parts.size)
                repeat(parts.size) { index ->
                    sentPendingIntents.add(
                        PendingIntent.getBroadcast(
                            this,
                            action.hashCode() + index,
                            Intent(action).apply { putExtra("partIndex", index) },
                            pendingIntentFlags,
                        ),
                    )
                }
                smsManager.sendMultipartTextMessage(
                    phoneNumber,
                    null,
                    ArrayList(parts),
                    sentPendingIntents,
                    null,
                )
            }
        } catch (e: Exception) {
            finish(
                mapOf(
                    "success" to false,
                    "errorMessage" to (e.message ?: "Direct SMS failed."),
                ),
            )
        }
    }

    private fun getSmsManager(subscriptionId: Int?): SmsManager {
        if (
            subscriptionId != null &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1
        ) {
            return SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
        }
        return SmsManager.getDefault()
    }

    private fun getSmsSubscriptions(): List<Map<String, Any?>> {
        if (
            Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1 ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_PHONE_STATE,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return emptyList()
        }

        val subscriptionManager = getSystemService(SubscriptionManager::class.java)
        val defaultSmsSubscriptionId = SubscriptionManager.getDefaultSmsSubscriptionId()
        val activeSubscriptions = try {
            subscriptionManager.activeSubscriptionInfoList ?: emptyList()
        } catch (_: SecurityException) {
            emptyList()
        }

        return activeSubscriptions.map { info ->
            mapOf(
                "subscriptionId" to info.subscriptionId,
                "displayName" to (info.displayName?.toString() ?: "SIM"),
                "carrierName" to (info.carrierName?.toString() ?: ""),
                "simSlotIndex" to info.simSlotIndex,
                "isDefault" to (info.subscriptionId == defaultSmsSubscriptionId),
            )
        }
    }

    private fun getBatteryLevel(): Int? {
        val batteryManager = getSystemService(BATTERY_SERVICE) as? BatteryManager
        val level =
            batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                ?: return null
        return if (level in 0..100) level else null
    }

    private fun getTelephonyNetworkInfo(): Map<String, Any?> {
        return try {
            val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                ?: return mapOf("success" to false)
            val networkOperatorName = telephonyManager.networkOperatorName ?: ""
            val simOperatorName = telephonyManager.simOperatorName ?: ""
            val networkCountryIso = telephonyManager.networkCountryIso ?: ""
            val simCountryIso = telephonyManager.simCountryIso ?: ""
            mapOf(
                "success" to true,
                "networkOperatorName" to networkOperatorName,
                "simOperatorName" to simOperatorName,
                "networkCountryIso" to networkCountryIso.uppercase(),
                "simCountryIso" to simCountryIso.uppercase(),
            )
        } catch (e: Exception) {
            mapOf("success" to false, "errorMessage" to e.message)
        }
    }

    private fun saveRecordingToDownloads(
        sourcePath: String,
        displayName: String,
    ): Map<String, Any?> {
        return try {
            val sourceFile = File(sourcePath)
            if (!sourceFile.exists()) {
                return mapOf(
                    "success" to false,
                    "errorMessage" to "Source recording file not found.",
                )
            }

            var exportedPath = ""
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                    put(MediaStore.MediaColumns.MIME_TYPE, "audio/mp4")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        "${Environment.DIRECTORY_DOWNLOADS}/SafeRoute/SOS_Recordings",
                    )
                }

                val resolver = applicationContext.contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: return mapOf(
                        "success" to false,
                        "errorMessage" to "Unable to create destination file.",
                    )

                FileInputStream(sourceFile).use { input ->
                    resolver.openOutputStream(uri)?.use { output ->
                        input.copyTo(output)
                    } ?: return mapOf(
                        "success" to false,
                        "errorMessage" to "Unable to open download destination.",
                    )
                }

                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)

                exportedPath = "/storage/emulated/0/${Environment.DIRECTORY_DOWNLOADS}/SafeRoute/SOS_Recordings/$displayName"
            }

            // Always write legacy public copy to Downloads/SafeRoute/SOS_Recordings & Music/SoundRecorder for maximum compatibility
            val targetDir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "SafeRoute/SOS_Recordings",
            )
            if (!targetDir.exists()) {
                targetDir.mkdirs()
            }
            val targetFile = File(targetDir, displayName)
            sourceFile.copyTo(targetFile, overwrite = true)
            exportedPath = targetFile.absolutePath

            // Also copy to SoundRecorder public folder so com.android.soundrecorder picks it up
            try {
                val soundRecorderDir = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
                    "SoundRecorder",
                )
                if (!soundRecorderDir.exists()) {
                    soundRecorderDir.mkdirs()
                }
                val srFile = File(soundRecorderDir, displayName)
                sourceFile.copyTo(srFile, overwrite = true)
                MediaScannerConnection.scanFile(
                    applicationContext,
                    arrayOf(srFile.absolutePath, targetFile.absolutePath),
                    arrayOf("audio/m4a", "audio/mp4", "audio/*"),
                    null
                )
            } catch (_: Exception) {}

            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(targetFile.absolutePath),
                arrayOf("audio/m4a", "audio/mp4", "audio/*"),
                null
            )

            mapOf(
                "success" to true,
                "publicPath" to exportedPath,
            )
        } catch (e: Exception) {
            mapOf(
                "success" to false,
                "errorMessage" to (e.message ?: "Failed to save recording to Downloads."),
            )
        }
    }

    private fun openFile(path: String): Map<String, Any?> {
        return try {
            val file = File(path)
            if (!file.exists()) {
                return mapOf(
                    "success" to false,
                    "errorMessage" to "Recording file not found.",
                )
            }

            val uri =
                FileProvider.getUriForFile(
                    this,
                    "${BuildConfig.APPLICATION_ID}.fileprovider",
                    file,
                )
            val mimeType = contentResolver.getType(uri) ?: "audio/*"
            val intent =
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, mimeType)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }

            if (intent.resolveActivity(packageManager) == null) {
                return mapOf(
                    "success" to false,
                    "errorMessage" to "No app is available to open this recording.",
                )
            }

            val chooser = Intent.createChooser(intent, "Open SOS Recording")
            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(chooser)
            mapOf("success" to true)
        } catch (e: Exception) {
            mapOf(
                "success" to false,
                "errorMessage" to (e.message ?: "Unable to open recording file."),
            )
        }
    }

    private fun makeDirectCall(phoneNumber: String, result: MethodChannel.Result) {
        val cleanNumber = phoneNumber.replace("[^0-9+]".toRegex(), "")
        val isEmergencyNumber = cleanNumber == "112" || cleanNumber == "911" || cleanNumber == "100" || cleanNumber == "101" || cleanNumber == "102"

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
            // No CALL_PHONE permission — open dialer as last resort
            try {
                val fallbackIntent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$cleanNumber")).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(fallbackIntent)
                result.success(mapOf("success" to true, "openedDialer" to true, "isEmergency" to isEmergencyNumber))
            } catch (ex: Exception) {
                result.success(mapOf("success" to false, "errorMessage" to (ex.message ?: "Direct call failed.")))
            }
            return
        }

        // ── Attempt 1: Plain ACTION_CALL (no extras — avoids MIUI emergency interception) ──
        try {
            val uri = Uri.parse("tel:$cleanNumber")
            val intent = Intent(Intent.ACTION_CALL, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                // DO NOT set IS_EMERGENCY_CALL — MIUI intercepts it and shows dial-pad freeze
            }
            startActivity(intent)
            result.success(mapOf("success" to true, "openedDialer" to false, "isEmergency" to isEmergencyNumber))
            return
        } catch (_: Exception) {
            // Attempt 1 failed, continue to retry strategies
        }

        // ── Attempt 2 (emergency only): Retry ACTION_CALL with CLEAR_TOP to force through ──
        if (isEmergencyNumber) {
            try {
                val uri = Uri.parse("tel:$cleanNumber")
                val retryIntent = Intent(Intent.ACTION_CALL, uri).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                }
                startActivity(retryIntent)
                result.success(mapOf("success" to true, "openedDialer" to false, "isEmergency" to true))
                return
            } catch (_: Exception) {
                // Attempt 2 also failed, fall through
            }
        }

        // ── Attempt 3 (non-emergency fallback): ACTION_DIAL opens keypad ──
        try {
            val fallbackIntent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$cleanNumber")).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(fallbackIntent)
            result.success(mapOf("success" to true, "openedDialer" to true, "isEmergency" to isEmergencyNumber))
        } catch (ex: Exception) {
            result.success(mapOf("success" to false, "errorMessage" to (ex.message ?: "Direct call failed.")))
        }
    }

    private fun startCallListener(result: MethodChannel.Result) {
        val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        if (telephonyManager == null) {
            result.success(mapOf("success" to false, "errorMessage" to "TelephonyManager unavailable."))
            return
        }

        try {
            val listener = object : PhoneStateListener() {
                @Suppress("DEPRECATION")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    val stateString = when (state) {
                        TelephonyManager.CALL_STATE_OFFHOOK -> "OFFHOOK"
                        TelephonyManager.CALL_STATE_RINGING -> "RINGING"
                        TelephonyManager.CALL_STATE_IDLE -> "IDLE"
                        else -> "UNKNOWN"
                    }
                    val methodChannel = MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, smsChannelName)
                    methodChannel.invokeMethod("onCallStateChanged", mapOf("state" to stateString))
                }
            }
            @Suppress("DEPRECATION")
            telephonyManager.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            result.success(mapOf("success" to true))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "errorMessage" to (e.message ?: "Failed to start call state listener.")))
        }
    }

    private fun resolveLocationSettings(result: MethodChannel.Result) {
        val locationRequest = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 5000).build()
        val builder = LocationSettingsRequest.Builder().addLocationRequest(locationRequest).setAlwaysShow(true)
        val client = LocationServices.getSettingsClient(this)
        val task = client.checkLocationSettings(builder.build())

        task.addOnSuccessListener {
            result.success(mapOf("success" to true, "resolutionRequired" to false))
        }
        task.addOnFailureListener { exception ->
            if (exception is ResolvableApiException) {
                try {
                    exception.startResolutionForResult(this, 1001)
                    result.success(mapOf("success" to true, "resolutionRequired" to true))
                } catch (e: Exception) {
                    result.success(mapOf("success" to false, "errorMessage" to e.message))
                }
            } else {
                result.success(mapOf("success" to false, "errorMessage" to exception.message))
            }
        }
    }

    private fun pickContactFromPhonebook(result: MethodChannel.Result) {
        try {
            pendingContactPickerResult = result
            val intent = Intent(Intent.ACTION_PICK, android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI)
            startActivityForResult(intent, REQUEST_CODE_PICK_CONTACT)
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "errorMessage" to (e.message ?: "Failed to open phonebook.")))
            pendingContactPickerResult = null
        }
    }

    private fun pickImageFromGallery(result: MethodChannel.Result) {
        try {
            pendingImagePickerResult = result
            val intent = Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
            startActivityForResult(intent, REQUEST_CODE_PICK_IMAGE)
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "errorMessage" to (e.message ?: "Failed to open gallery.")))
            pendingImagePickerResult = null
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_PICK_IMAGE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val imageUri = data.data
                if (imageUri != null) {
                    try {
                        val inputStream = contentResolver.openInputStream(imageUri)
                        val outputFile = File(filesDir, "user_profile_avatar.jpg")
                        outputFile.outputStream().use { outputStream ->
                            inputStream?.copyTo(outputStream)
                        }
                        val imagePath = outputFile.absolutePath
                        val prefs = getSharedPreferences("safe_route_picker", Context.MODE_PRIVATE)
                        prefs.edit().putString("pending_profile_image", imagePath).apply()

                        pendingImagePickerResult?.success(mapOf(
                            "success" to true,
                            "imagePath" to imagePath
                        ))
                        pendingImagePickerResult = null
                        return
                    } catch (e: Exception) {
                        pendingImagePickerResult?.success(mapOf("success" to false, "errorMessage" to (e.message ?: "Failed saving image.")))
                        pendingImagePickerResult = null
                        return
                    }
                }
            }
            pendingImagePickerResult?.success(mapOf("success" to false, "errorMessage" to "No image selected."))
            pendingImagePickerResult = null
        }

        if (requestCode == REQUEST_CODE_PICK_CONTACT) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val contactUri = data.data
                if (contactUri != null) {
                    val projection = arrayOf(
                        android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER,
                        android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME
                    )
                    contentResolver.query(contactUri, projection, null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val numberIndex = cursor.getColumnIndex(android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER)
                            val nameIndex = cursor.getColumnIndex(android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                            val number = if (numberIndex >= 0) cursor.getString(numberIndex) else ""
                            val name = if (nameIndex >= 0) cursor.getString(nameIndex) else ""
                            
                            val prefs = getSharedPreferences("safe_route_picker", Context.MODE_PRIVATE)
                            prefs.edit().putString("pending_phone", number).putString("pending_name", name).apply()

                            pendingContactPickerResult?.success(mapOf(
                                "success" to true,
                                "phoneNumber" to number,
                                "name" to name
                            ))
                            pendingContactPickerResult = null
                            return
                        }
                    }
                }
            }
            pendingContactPickerResult?.success(mapOf("success" to false, "errorMessage" to "No contact selected."))
            pendingContactPickerResult = null
        }
    }

    private fun getGeofencePendingIntent(): PendingIntent {
        if (geofencePendingIntent != null) {
            return geofencePendingIntent!!
        }
        val intent = Intent(this, GeofenceBroadcastReceiver::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_MUTABLE else 0)
        geofencePendingIntent = PendingIntent.getBroadcast(this, 9001, intent, flags)
        return geofencePendingIntent!!
    }

    private fun registerGeofencesNative(zones: List<Map<String, Any>>, result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            result.error("PERMISSION_DENIED", "ACCESS_FINE_LOCATION is required for Geofencing", null)
            return
        }

        if (zones.isEmpty()) {
            result.success(mapOf("success" to true, "count" to 0))
            return
        }

        val geofenceList = ArrayList<Geofence>()
        for (zone in zones) {
            val id = zone["id"]?.toString() ?: continue
            val lat = (zone["latitude"] as? Number)?.toDouble() ?: continue
            val lng = (zone["longitude"] as? Number)?.toDouble() ?: continue
            val radius = (zone["radius"] as? Number)?.toFloat() ?: 400f

            val geofence = Geofence.Builder()
                .setRequestId(id)
                .setCircularRegion(lat, lng, radius)
                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
                .build()

            geofenceList.add(geofence)
        }

        if (geofenceList.isEmpty()) {
            result.success(mapOf("success" to true, "count" to 0))
            return
        }

        val request = GeofencingRequest.Builder()
            .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
            .addGeofences(geofenceList)
            .build()

        try {
            geofencingClient.addGeofences(request, getGeofencePendingIntent()).run {
                addOnSuccessListener {
                    android.util.Log.i("MainActivity", "Successfully registered ${geofenceList.size} native geofences.")
                    result.success(mapOf("success" to true, "count" to geofenceList.size))
                }
                addOnFailureListener { e ->
                    android.util.Log.e("MainActivity", "Failed to register geofences: ${e.message}")
                    result.error("GEOFENCE_REGISTRATION_FAILED", e.message, null)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Exception adding geofences: ${e.message}")
            result.error("GEOFENCE_EXCEPTION", e.message, null)
        }
    }

    private fun removeGeofencesNative(ids: List<String>, result: MethodChannel.Result) {
        if (ids.isEmpty()) {
            result.success(mapOf("success" to true))
            return
        }
        try {
            geofencingClient.removeGeofences(ids).run {
                addOnSuccessListener {
                    result.success(mapOf("success" to true))
                }
                addOnFailureListener { e ->
                    result.error("GEOFENCE_REMOVE_FAILED", e.message, null)
                }
            }
        } catch (e: Exception) {
            result.error("GEOFENCE_REMOVE_EXCEPTION", e.message, null)
        }
    }

    private fun removeAllGeofencesNative(result: MethodChannel.Result) {
        try {
            geofencingClient.removeGeofences(getGeofencePendingIntent()).run {
                addOnSuccessListener {
                    result.success(mapOf("success" to true))
                }
                addOnFailureListener { e ->
                    result.error("GEOFENCE_REMOVE_ALL_FAILED", e.message, null)
                }
            }
        } catch (e: Exception) {
            result.error("GEOFENCE_REMOVE_ALL_EXCEPTION", e.message, null)
        }
    }
}
