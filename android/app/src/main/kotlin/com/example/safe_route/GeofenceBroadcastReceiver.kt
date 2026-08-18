package com.example.safe_route

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.GeofencingEvent

class GeofenceBroadcastReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "GeofenceReceiver"
        private const val CHANNEL_ID = "safe_route_geofence_channel"
        private const val CHANNEL_NAME = "SafeRoute Geofence Alerts"

        // Callback reference to MainActivity for forwarding events to Flutter
        var eventListener: ((Map<String, Any?>) -> Unit)? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        val geofencingEvent = GeofencingEvent.fromIntent(intent)
        if (geofencingEvent == null) {
            Log.e(TAG, "GeofencingEvent is null")
            return
        }

        if (geofencingEvent.hasError()) {
            val errorMessage = GeofenceStatusCodes.getStatusCodeString(geofencingEvent.errorCode)
            Log.e(TAG, "Geofence transition error: $errorMessage (code ${geofencingEvent.errorCode})")
            return
        }

        val geofenceTransition = geofencingEvent.geofenceTransition
        val triggeringGeofences = geofencingEvent.triggeringGeofences

        if (triggeringGeofences.isNullOrEmpty()) {
            Log.w(TAG, "No triggering geofences found")
            return
        }

        val transitionTypeString = when (geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> "ENTER"
            Geofence.GEOFENCE_TRANSITION_EXIT -> "EXIT"
            Geofence.GEOFENCE_TRANSITION_DWELL -> "DWELL"
            else -> "UNKNOWN"
        }

        val location = geofencingEvent.triggeringLocation
        val lat = location?.latitude ?: 0.0
        val lng = location?.longitude ?: 0.0

        for (geofence in triggeringGeofences) {
            val geofenceId = geofence.requestId
            Log.i(TAG, "Geofence Transition Detected: $transitionTypeString for ID: $geofenceId at ($lat, $lng)")

            val payload = mapOf<String, Any?>(
                "geofenceId" to geofenceId,
                "transitionType" to transitionTypeString,
                "latitude" to lat,
                "longitude" to lng,
                "timestamp" to System.currentTimeMillis()
            )

            // Forward to active Flutter MethodChannel listener if connected
            try {
                eventListener?.invoke(payload)
            } catch (e: Exception) {
                Log.e(TAG, "Error notifying Flutter listener: ${e.message}")
            }

            // If entering a safety risk geofence, fire a native Android Notification
            if (geofenceTransition == Geofence.GEOFENCE_TRANSITION_ENTER) {
                if (geofenceId == "dest_geofence") {
                    sendNativeNotification(
                        context,
                        "🎯 Destination Reached!",
                        "You have safely arrived at your destination.",
                        10001
                    )
                } else {
                    val zoneName = geofenceId.replace("seed_", "").replace("_", " ")
                    sendNativeNotification(
                        context,
                        "⚠️ SafeRoute Safety Alert",
                        "Approaching or entering reported high-risk zone ($zoneName). Stay alert.",
                        geofenceId.hashCode()
                    )
                }
            }
        }
    }

    private fun sendNativeNotification(context: Context, title: String, body: String, notificationId: Int) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Live safety zone alerts for Journey Guard"
                enableVibration(true)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        notificationManager.notify(notificationId, notification)
    }
}
