package com.nexa.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.IInterface
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.RemoteException
import android.preference.PreferenceManager
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
///   2. Sends a "wake word detected" signal via a MethodChannel extra
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
        const val PREFS_KEY = "wake_word_enabled"

        // Known wake phrase variants (matching Dart-side patterns)
        val WAKE_PHRASES = listOf(
            "hey nexa", "hi nexa", "okay nexa", "ok nexa",
            "hey nexus", "hey next", "hey next up", "hey next uh",
            "hey nixa", "hey neksa", "hey nexta",
            "hey alexa", "hey lexa",  // common misrecognitions
            "nexa wake up", "nexus wake up", "nexa start listening"
        )
    }

    private var speechRecognizer: SpeechRecognizer? = null
    private var isListening = false
    private var isPaused = false
    private val handler = Handler(Looper.getMainLooper())
    private var lastWakeTime: Long = 0
    private val MIN_WAKE_INTERVAL_MS = 3000L  // Prevent double-triggering

    // Flutter method channel for communicating wake events back
    private var wakeEventChannel: android.os.IBinder? = null

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

        // Start as foreground service with persistent notification
        val notification = buildNotification("Listening for \"Hey Nexa\"…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN) {
            startForeground(NOTIFICATION_ID, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Start listening
        startListening()
        return START_STICKY  // Restart if killed by the system
    }

    override fun onDestroy() {
        Log.d(TAG, "WakeWordForegroundService destroyed")
        stopListening()
        super.onDestroy()
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
                android.speech.RecognizerIntent.LANG_MODEL_FREE_FORM)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE, "en-US")
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "en-US")
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, false)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            // Keep listening for a longer window to catch the wake phrase
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 5000L)
            listenIntent.putExtra(android.speech.RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 3000L)

            speechRecognizer?.startListening(listenIntent)
            isListening = true
            Log.d(TAG, "Started listening for wake word")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start listening: ${e.message}")
            isListening = false
            // Retry after a delay
            handler.postDelayed({ startListening() }, 2000)
        }
    }

    private fun stopListening() {
        isListening = false
        try {
            speechRecognizer?.stopListening()
        } catch (_: Exception) {}
        try {
            speechRecognizer?.destroy()
        } catch (_: Exception) {}
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
        // Restart listening to keep the loop going
        if (!isPaused) restartListening(500)
    }

    override fun onPartialResults(partialResults: Bundle?) {
        // Check partial results for wake word — faster detection
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

        // No wake word found — restart listening
        if (!isPaused) restartListening(400)
    }

    override fun onError(error: Int) {
        val errorMsg = getErrorDescription(error)
        Log.e(TAG, "Speech recognition error: $error ($errorMsg)")
        isListening = false

        // Errors 6 (no speech) and 7 (no match) are normal — just restart
        // Error 1 (network) — restart after longer delay
        // Error 2 (client) — may need to recreate recognizer
        val restartDelay = when (error) {
            6, 7 -> 400L   // No speech / no match — normal, restart quickly
            1, 2 -> 3000L  // Network / client side — longer delay
            3, 4, 5 -> 5000L  // Audio / server side — even longer
            8, 9 -> 2000L  // Insufficient permissions / busy
            else -> 2000L
        }

        // For client-side errors, recreate the recognizer
        if (error == 2 || error == 9) {
            try {
                speechRecognizer?.destroy()
            } catch (_: Exception) {}
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

        for (phrase in WAKE_PHRASES) {
            val idx = normalized.indexOf(phrase)
            if (idx >= 0) {
                val trailing = normalized.substring(idx + phrase.length).trim()
                // Map trailing back from normalized to original text
                // Just return the original text after the wake phrase position
                val originalAfterWake = text.substring(
                    minOf(idx + phrase.length, text.length)
                ).trim()
                return originalAfterWake
            }
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

        // Update notification
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
                NotificationManager.IMPORTANCE_LOW  // Low priority — no sound/vibration
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

    // ─── Helpers ────────────────────────────────────────────────────────

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
