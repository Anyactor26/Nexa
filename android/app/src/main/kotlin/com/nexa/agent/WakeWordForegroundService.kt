package com.nexa.agent

import android.accessibilityservice.GestureDescription
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.core.app.NotificationCompat

/// A foreground service that continuously listens for the wake phrase
/// "Hey Nexa" using Android's on-device SpeechRecognizer — even when the
/// app is closed, backgrounded, or killed by the system.
///
/// When the wake word is detected, it:
///   1. Launches the Nexa MainActivity to the foreground
///   2. Sends a "wake word detected" signal via intent extras
///   3. Pauses listening briefly to avoid double-triggering
///
/// Android requires FOREGROUND_SERVICE_MICROPHONE (API 34+) for mic access
/// inside a foreground service. The persistent notification keeps Android
/// from killing the service.
class WakeWordForegroundService : Service(), RecognitionListener {

    companion object {
        const val TAG = "NexaWakeWord"
        const val CHANNEL_ID = "nexa_wake_word_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.nexa.agent.START_WAKE_WORD"
        const val ACTION_STOP = "com.nexa.agent.STOP_WAKE_WORD"
        const val EXTRA_WAKE_WORD_DETECTED = "wake_word_detected"
        const val EXTRA_TRAILING_TEXT = "trailing_text"
        const val EXTRA_DISMISS_KEYGUARD = "dismiss_keyguard"

        // Known wake phrase variants (matching Dart-side patterns)
        val WAKE_PHRASES = listOf(
            "hey nexa", "hi nexa", "okay nexa", "ok nexa",
            "hey nexus", "hey next", "hey next up", "hey next uh",
            "hey nixa", "hey neksa", "hey nexta",
            "hey alexa", "hey lexa",  // common misrecognitions
            "nexa wake up", "nexus wake up", "nexa start listening"
        )

        // Lock/unlock phone command constants for the native layer
        const val ACTION_LOCK_SCREEN = "com.nexa.agent.LOCK_SCREEN"
        const val ACTION_UNLOCK_SCREEN = "com.nexa.agent.UNLOCK_SCREEN"
    }

    private var speechRecognizer: SpeechRecognizer? = null
    private var isListening = false
    private var isPaused = false
    private val handler = Handler(Looper.getMainLooper())
    private var lastWakeTime: Long = 0
    private val MIN_WAKE_INTERVAL_MS = 3000L  // Prevent double-triggering

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.d(TAG, "WakeWordForegroundService created")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: action=${intent?.action}")

        if (intent?.action == ACTION_STOP) {
            stopListening()
            stopSelf()
            return START_NOT_STICKY
        }

        // Always promote to the foreground before doing anything else. If we
        // were launched with startForegroundService() and fail to call
        // startForeground() within ~5s, Android kills the process with a
        // ForegroundServiceDidNotStartInTimeException.
        if (!enterForeground()) {
            // Microphone FGS can be refused (e.g. permission revoked, or a
            // background start on Android 12+). Nothing else is safe to do.
            stopSelf()
            return START_NOT_STICKY
        }

        // Handle lock/unlock commands from the service layer
        if (intent?.action == ACTION_LOCK_SCREEN) {
            lockScreen()
            return START_STICKY
        }
        if (intent?.action == ACTION_UNLOCK_SCREEN) {
            unlockScreen()
            return START_STICKY
        }

        // Start listening
        startListening()
        return START_STICKY  // Restart if killed by the system
    }

    /// Promotes the service to the foreground with the persistent notification.
    /// Returns false when the platform refuses the start (missing RECORD_AUDIO,
    /// background-start restrictions on Android 12+, etc.) so callers can bail
    /// out instead of crashing.
    private fun enterForeground(): Boolean {
        return try {
            val notification = buildNotification("Listening for \"Hey Nexa\"…")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID, notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Could not enter foreground: ${e.message}")
            false
        }
    }

    override fun onDestroy() {
        Log.d(TAG, "WakeWordForegroundService destroyed")
        stopListening()
        super.onDestroy()
    }

    // ─── Lock / Unlock Screen ──────────────────────────────────────────

    /// Locks the screen by pressing the POWER key (keyevent 26).
    /// This works from a foreground service without Shizuku/root.
    private fun lockScreen() {
        Log.d(TAG, "Locking screen")
        try {
            // Use the accessibility service if available for a more reliable lock
            val service = AgentAccessibilityService.instance
            if (service != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                // Accessibility service can perform GLOBAL_ACTION_LOCK_SCREEN on API 28+
                service.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN)
                Log.d(TAG, "Locked screen via accessibility GLOBAL_ACTION_LOCK_SCREEN")
            } else {
                // No accessibility service or pre-API 28 — use shell command
                Runtime.getRuntime().exec(arrayOf("/system/bin/sh", "-c", "input keyevent 26"))
                Log.d(TAG, "Locked screen via shell power keyevent")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to lock screen: ${e.message}")
        }
    }

    /// Wakes and unlocks the screen: presses power to wake, optionally swipes
    /// up via the accessibility service (for swipe-only keyguards), then
    /// launches MainActivity, which requests a proper keyguard dismissal via
    /// KeyguardManager.requestDismissKeyguard().
    private fun unlockScreen() {
        Log.d(TAG, "Unlocking screen")
        try {
            // First: wake the screen by pressing power
            Runtime.getRuntime().exec(arrayOf("/system/bin/sh", "-c", "input keyevent 26"))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to wake screen: ${e.message}")
        }
        // onStartCommand runs on the main thread — never Thread.sleep() here or
        // the service ANRs. Continue after the screen has had time to wake.
        handler.postDelayed({ finishUnlock() }, 500)
    }

    private fun finishUnlock() {
        try {
            // Try a swipe-up gesture to dismiss a swipe-only keyguard.
            // There is no public accessibility global action for dismissing the
            // keyguard, so secure keyguards are handled by MainActivity through
            // KeyguardManager.requestDismissKeyguard().
            val service = AgentAccessibilityService.instance
            if (service != null) {
                val metrics = resources.displayMetrics
                val x = metrics.widthPixels / 2f
                val path = android.graphics.Path()
                path.moveTo(x, metrics.heightPixels * 0.9f)
                path.lineTo(x, metrics.heightPixels * 0.15f)
                val gesture = GestureDescription.Builder()
                    .addStroke(GestureDescription.StrokeDescription(path, 0, 500))
                    .build()
                service.dispatchGesture(gesture, null, null)
                Log.d(TAG, "Attempted unlock via swipe gesture")
            } else {
                Log.w(TAG, "Accessibility service not running — cannot swipe to unlock")
            }

            // Launch Nexa, asking it to show over the keyguard and dismiss it.
            val launchIntent = Intent(this, MainActivity::class.java)
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            launchIntent.putExtra(EXTRA_DISMISS_KEYGUARD, true)
            startActivity(launchIntent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to unlock screen: ${e.message}")
        }
    }

    // ─── Speech Recognition ────────────────────────────────────────────

    private fun startListening() {
        if (isPaused || isListening) return

        try {
            if (speechRecognizer == null) {
                speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this)
                speechRecognizer?.setRecognitionListener(this)
            }

            val listenIntent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "en-US")
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, false)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 5000L)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 3000L)

            speechRecognizer?.startListening(listenIntent)
            isListening = true
            Log.d(TAG, "Started listening for wake word")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start listening: ${e.message}")
            isListening = false
            handler.postDelayed({ startListening() }, 2000)
        }
    }

    private fun stopListening() {
        isListening = false
        try { speechRecognizer?.stopListening() } catch (_: Exception) {}
        try { speechRecognizer?.destroy() } catch (_: Exception) {}
        speechRecognizer = null
    }

    private fun restartListening(delayMs: Long = 400) {
        isListening = false
        handler.postDelayed({
            if (!isPaused) startListening()
        }, delayMs)
    }

    // ─── RecognitionListener callbacks ─────────────────────────────────

    override fun onReadyForSpeech(params: Bundle?) {
        Log.d(TAG, "Ready for speech")
        isListening = true
    }

    override fun onBeginningOfSpeech() {
        Log.d(TAG, "Beginning of speech detected")
    }

    override fun onRmsChanged(rmsdB: Float) {}

    override fun onBufferReceived(buffer: ByteArray?) {}

    override fun onEndOfSpeech() {
        Log.d(TAG, "End of speech")
        isListening = false
        if (!isPaused) restartListening(500)
    }

    override fun onPartialResults(partialResults: Bundle?) {
        val matches = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        if (matches != null) {
            for (match in matches) {
                if (containsWakeWord(match)) {
                    handleWakeWordDetected(match)
                    return
                }
            }
        }
    }

    override fun onResults(results: Bundle?) {
        val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        Log.d(TAG, "Results: $matches")

        if (matches != null) {
            for (match in matches) {
                if (containsWakeWord(match)) {
                    handleWakeWordDetected(match)
                    return
                }
            }
        }

        if (!isPaused) restartListening(400)
    }

    override fun onError(error: Int) {
        val errorMsg = getErrorDescription(error)
        Log.e(TAG, "Speech recognition error: $error ($errorMsg)")
        isListening = false

        val restartDelay = when (error) {
            6, 7 -> 400L   // No speech / no match — normal, restart quickly
            1, 2 -> 3000L  // Network / client side — longer delay
            3, 4, 5 -> 5000L  // Audio / server side — even longer
            8, 9 -> 2000L  // Insufficient permissions / busy
            else -> 2000L
        }

        // For client-side errors, recreate the recognizer
        if (error == 2 || error == 9) {
            try { speechRecognizer?.destroy() } catch (_: Exception) {}
            speechRecognizer = null
        }

        if (!isPaused) {
            handler.postDelayed({ startListening() }, restartDelay)
        }
    }

    override fun onEvent(eventType: Int, params: Bundle?) {}

    // ─── Wake Word Detection ───────────────────────────────────────────

    private fun containsWakeWord(text: String): Boolean {
        val normalized = text.lowercase()
            .replace(Regex("[^a-z0-9\\s]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()

        if (normalized.isEmpty()) return false

        for (phrase in WAKE_PHRASES) {
            if (normalized.contains(phrase)) return true
        }
        return false
    }

    private fun extractTrailingText(text: String): String {
        val normalized = text.lowercase()
            .replace(Regex("[^a-z0-9\\s]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()

        // NOTE: offsets from `normalized` must not be applied to `text` — the
        // lowercase/punctuation/whitespace collapsing shifts them. Slice the
        // normalized string, which is also what the Dart side consumes.
        var best = -1
        var bestEnd = 0
        for (phrase in WAKE_PHRASES) {
            val idx = normalized.indexOf(phrase)
            if (idx >= 0 && (best == -1 || idx < best)) {
                best = idx
                bestEnd = idx + phrase.length
            }
        }
        if (best >= 0) {
            return normalized.substring(minOf(bestEnd, normalized.length)).trim()
        }
        return ""
    }

    private fun handleWakeWordDetected(rawText: String) {
        val now = System.currentTimeMillis()
        if (now - lastWakeTime < MIN_WAKE_INTERVAL_MS) {
            Log.d(TAG, "Wake word double-trigger suppressed")
            restartListening(1000)
            return
        }
        lastWakeTime = now

        val trailingText = extractTrailingText(rawText)
        Log.d(TAG, "WAKE WORD DETECTED! Raw: \"$rawText\", Trailing: \"$trailingText\"")

        // Pause listening to avoid detecting our own TTS or app sounds
        isPaused = true
        isListening = false
        try { speechRecognizer?.stopListening() } catch (_: Exception) {}

        updateNotification("Wake word detected! Opening Nexa…")

        // Launch the Nexa app to foreground with wake word data
        val launchIntent = Intent(this, MainActivity::class.java)
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        launchIntent.putExtra(EXTRA_WAKE_WORD_DETECTED, true)
        launchIntent.putExtra(EXTRA_TRAILING_TEXT, trailingText)
        startActivity(launchIntent)

        // Resume listening after a delay (once app sounds have played)
        handler.postDelayed({
            isPaused = false
            updateNotification("Listening for \"Hey Nexa\"…")
            startListening()
        }, 5000)
    }

    // ─── Notification ───────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Nexa Wake Word Listener",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Continuously listens for the \"Hey Nexa\" wake phrase"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(statusText: String): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, WakeWordForegroundService::class.java)
        stopIntent.action = ACTION_STOP
        val stopPendingIntent = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Nexa")
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(pendingIntent)
            .addAction(android.R.drawable.ic_media_pause, "Stop listening", stopPendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun updateNotification(statusText: String) {
        try {
            val notification = buildNotification(statusText)
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to update notification: ${e.message}")
        }
    }

    private fun getErrorDescription(error: Int): String {
        return when (error) {
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Network timeout"
            SpeechRecognizer.ERROR_NETWORK -> "Network error"
            SpeechRecognizer.ERROR_AUDIO -> "Audio recording error"
            SpeechRecognizer.ERROR_SERVER -> "Server error"
            SpeechRecognizer.ERROR_CLIENT -> "Client side error"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No speech input"
            SpeechRecognizer.ERROR_NO_MATCH -> "No recognition match"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Recognizer busy"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Insufficient permissions"
            else -> "Unknown error ($error)"
        }
    }
}
