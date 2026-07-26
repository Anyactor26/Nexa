package com.nexa.agent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/// Automatically restarts the wake-word foreground service after a device
/// reboot (only if the user has previously enabled "Hey Nexa" in settings).
class WakeWordBootReceiver : BroadcastReceiver() {
    companion object {
        const val TAG = "NexaBootReceiver"
        const val PREFS_KEY = "wake_word_enabled"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON") {
            return
        }

        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        // Flutter's SharedPreferences adds a "flutter." prefix to keys on Android
        val isEnabled = prefs.getBoolean("flutter.$PREFS_KEY", false)
        Log.d(TAG, "Boot completed. wake_word_enabled = $isEnabled")

        if (!isEnabled) return

        // Start the foreground wake-word service.
        // On Android 12+ a service started from BOOT_COMPLETED is denied
        // while-in-use permissions, so a microphone-typed FGS can throw
        // (ForegroundServiceStartNotAllowedException / SecurityException).
        // A crash here would put the device in a boot-loop of ANRs, so this
        // must never be allowed to escape onReceive().
        try {
            val serviceIntent = Intent(context, WakeWordForegroundService::class.java)
            serviceIntent.action = WakeWordForegroundService.ACTION_START
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Could not start wake-word service on boot: ${e.message}")
        }
    }
}
