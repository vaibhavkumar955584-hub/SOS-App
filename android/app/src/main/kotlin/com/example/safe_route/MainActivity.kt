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
import android.provider.MediaStore
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayList
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val smsChannelName = "safe_route/sms"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            smsChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
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

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values =
                    ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                        put(MediaStore.MediaColumns.MIME_TYPE, "audio/mp4")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                        put(
                            MediaStore.MediaColumns.RELATIVE_PATH,
                            "${Environment.DIRECTORY_DOWNLOADS}/SafeRoute/SOS_Recordings",
                        )
                    }

                val resolver = applicationContext.contentResolver
                val uri =
                    resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
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

                mapOf(
                    "success" to true,
                    "publicPath" to "Download/SafeRoute/SOS_Recordings/$displayName",
                )
            } else {
                val targetDir =
                    File(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                        "SafeRoute/SOS_Recordings",
                    )
                if (!targetDir.exists()) {
                    targetDir.mkdirs()
                }

                val targetFile = File(targetDir, displayName)
                sourceFile.copyTo(targetFile, overwrite = true)
                mapOf(
                    "success" to true,
                    "publicPath" to targetFile.absolutePath,
                )
            }
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
}
