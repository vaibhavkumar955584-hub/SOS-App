package com.example.safe_route

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Shared translucent entry point for both Home-Screen Widget and Launcher Shortcuts.
 * Requires a deliberate 2-second press-and-hold to prevent accidental pocket triggers.
 * Verifies permissions and invokes Flutter EmergencyDispatchEngine on confirmation.
 */
class SosShortcutActivity : Activity() {

    private val handler = Handler(Looper.getMainLooper())
    private var isTriggerConfirmed = false
    private var holdStartTime = 0L
    private val HOLD_DURATION_MS = 2000L

    private lateinit var progressHold: ProgressBar
    private lateinit var btnHold: Button
    private lateinit var btnCancel: Button
    private lateinit var txtInstruction: TextView

    private val requiredPermissions = arrayOf(
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.SEND_SMS,
        Manifest.permission.CALL_PHONE,
        Manifest.permission.RECORD_AUDIO
    )

    private val progressUpdater = object : Runnable {
        override fun run() {
            if (isTriggerConfirmed) return
            val elapsed = System.currentTimeMillis() - holdStartTime
            val progress = ((elapsed.toFloat() / HOLD_DURATION_MS) * 100).toInt().coerceIn(0, 100)
            progressHold.progress = progress

            val remainingSec = ((HOLD_DURATION_MS - elapsed) / 1000.0).coerceAtLeast(0.0)
            txtInstruction.text = "Hold for ${String.format("%.1f", remainingSec)}s to confirm..."

            if (elapsed < HOLD_DURATION_MS) {
                handler.postDelayed(this, 50)
            }
        }
    }

    private val triggerRunnable = Runnable {
        isTriggerConfirmed = true
        vibratePhone(500)
        dispatchSosTrigger()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_sos_shortcut)

        progressHold = findViewById(R.id.progress_hold)
        btnHold = findViewById(R.id.btn_hold_sos)
        btnCancel = findViewById(R.id.btn_cancel_shortcut)
        txtInstruction = findViewById(R.id.txt_instruction)

        // 1. Check Permissions Gate
        if (!hasAllRequiredPermissions()) {
            Toast.makeText(
                this,
                "VIGIL requires Location, SMS, Call & Audio permissions to trigger SOS. Opening app...",
                Toast.LENGTH_LONG
            ).show()
            val mainIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            startActivity(mainIntent)
            finish()
            return
        }

        // 2. Setup 2-Second Hold Listener
        btnHold.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    holdStartTime = System.currentTimeMillis()
                    isTriggerConfirmed = false
                    progressHold.visibility = View.VISIBLE
                    progressHold.progress = 0
                    vibratePhone(50)
                    handler.post(progressUpdater)
                    handler.postDelayed(triggerRunnable, HOLD_DURATION_MS)
                    true
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (!isTriggerConfirmed) {
                        handler.removeCallbacks(triggerRunnable)
                        handler.removeCallbacks(progressUpdater)
                        progressHold.visibility = View.INVISIBLE
                        progressHold.progress = 0
                        txtInstruction.text = "Press and HOLD the red button for 2 seconds to trigger SOS"
                        Toast.makeText(this, "SOS Cancelled. No alert sent.", Toast.LENGTH_SHORT).show()
                    }
                    true
                }

                else -> false
            }
        }

        btnCancel.setOnClickListener {
            handler.removeCallbacks(triggerRunnable)
            handler.removeCallbacks(progressUpdater)
            Toast.makeText(this, "Cancelled", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    private fun hasAllRequiredPermissions(): Boolean {
        for (perm in requiredPermissions) {
            if (ContextCompat.checkSelfPermission(this, perm) != PackageManager.PERMISSION_GRANTED) {
                return false
            }
        }
        return true
    }

    private fun vibratePhone(durationMs: Long) {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(durationMs)
        }
    }

    private fun dispatchSosTrigger() {
        val source = intent.getStringExtra("triggerSource") ?: "widget"

        // Forward to MainActivity to invoke Flutter EmergencyDispatchEngine
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = "ACTION_TRIGGER_SOS"
            putExtra("triggerSource", source)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        startActivity(launchIntent)
        Toast.makeText(this, "🚨 EMERGENCY SOS ACTIVATED!", Toast.LENGTH_SHORT).show()
        finish()
    }

    override fun onDestroy() {
        handler.removeCallbacks(triggerRunnable)
        handler.removeCallbacks(progressUpdater)
        super.onDestroy()
    }
}
