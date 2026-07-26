import 'dart:async';
import 'dart:developer' as developer;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

/// Continuously listens for the wake phrase "Hey Nexa".
///
/// **Architecture:**
///   • When the app is **foregrounded**, uses the Dart-level
///     `speech_to_text` plugin for fast, accurate wake-word detection.
///   • When the app is **backgrounded or closed**, delegates to the native
///     Android `WakeWordForegroundService`, which uses Android's
///     `SpeechRecognizer` in a foreground service that survives process
///     kills and reboots.
///
/// The two layers are coordinated so they never compete for the mic:
///   – When the app is foregrounded, the Dart listener is active and the
///     native service is optionally kept running but pauses its own mic.
///   – When the app goes to background, the Dart listener is paused and
///     the native service takes over.
///   – The native service can also wake the app up when it's completely
///     closed by launching the MainActivity with intent extras.
class WakeWordService {
  static const String prefsKey = 'wake_word_enabled';
  static const String _canonicalWakePhrase = 'hey nexa';

  // Method channel for communicating with the native foreground service
  static const MethodChannel _nativeChannel = MethodChannel('com.nexa.agent/wake_word');

  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isInitialized = false;
  bool _isEnabled = false;
  bool _isRunning = false;
  bool _isPaused = false;
  bool _handoffInProgress = false;
  bool _nativeServiceRunning = false;
  Timer? _restartTimer;
  DateTime? _lastWakeAt;

  /// Called whenever "Hey Nexa" is detected (from either Dart or native layer).
  void Function(String trailingText)? onWakeWord;

  bool get isEnabled => _isEnabled;
  bool get isListening => _isRunning;
  bool get isNativeServiceRunning => _nativeServiceRunning;

  Future<void> init({void Function(String trailingText)? onWakeWord}) async {
    if (onWakeWord != null) this.onWakeWord = onWakeWord;

    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(prefsKey) ?? false;

    // Listen for wake word events coming FROM the native foreground service
    _nativeChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onWakeWordDetected') {
        final args = call.arguments as Map?;
        final trailingText = (args?['trailingText'] as String?) ?? '';
        developer.log(
          'Wake word detected from NATIVE foreground service. Trailing: "$trailingText"',
          name: 'WakeWordService',
        );
        _handleWakeWord(trailingText);
      }
    });

    await _ensureInitialized();

    if (_isEnabled && _isInitialized) {
      _startListeningLoop();
      await _startNativeForegroundService();
    }
  }

  /// Enable or disable wake word detection. Persists to SharedPreferences.
  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, enabled);

    if (enabled) {
      await _ensureInitialized();
      _startListeningLoop();
      await _startNativeForegroundService();
    } else {
      await _stopListeningLoop();
      await _stopNativeForegroundService();
    }
  }

  // ─── Native foreground service control ───────────────────────────────

  Future<void> _startNativeForegroundService() async {
    try {
      await _nativeChannel.invokeMethod<bool>('startWakeWordService');
      _nativeServiceRunning = true;
      developer.log('Native wake word foreground service started', name: 'WakeWordService');
    } catch (e) {
      developer.log('Failed to start native wake word service: $e', name: 'WakeWordService');
      _nativeServiceRunning = false;
    }
  }

  Future<void> _stopNativeForegroundService() async {
    try {
      await _nativeChannel.invokeMethod<bool>('stopWakeWordService');
      _nativeServiceRunning = false;
      developer.log('Native wake word foreground service stopped', name: 'WakeWordService');
    } catch (e) {
      developer.log('Failed to stop native wake word service: $e', name: 'WakeWordService');
    }
  }

  // ─── Dart-level speech recognition (foreground) ──────────────────────

  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;

    _isInitialized = await _speech.initialize(
      onError: (error) {
        developer.log('WakeWordService error: $error', name: 'WakeWordService');
        _isRunning = false;
        if (_isEnabled && !_isPaused && !_handoffInProgress) {
          _restartSoon();
        }
      },
      onStatus: (status) {
        developer.log('WakeWordService status: $status', name: 'WakeWordService');
        if (status == 'done' || status == 'notListening') {
          _isRunning = false;
          if (_isEnabled && !_isPaused && !_handoffInProgress) {
            _restartSoon();
          }
        } else if (status == 'listening') {
          _isRunning = true;
        }
      },
    );
  }

  void pause() {
    _isPaused = true;
    _handoffInProgress = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _isRunning = false;
    _speech.stop();
  }

  void resume() {
    _isPaused = false;
    _handoffInProgress = false;
    _isRunning = false;
    if (_isEnabled) {
      _restartSoon(const Duration(milliseconds: 250));
    }
  }

  void _startListeningLoop() {
    if (_isPaused || !_isInitialized || !_isEnabled) return;
    if (_speech.isListening || _isRunning) return;
    _restartTimer?.cancel();
    _restartTimer = null;
    unawaited(_listenOnce());
  }

  Future<void> _stopListeningLoop() async {
    _restartTimer?.cancel();
    _restartTimer = null;
    _handoffInProgress = false;
    _isRunning = false;
    await _speech.stop();
  }

  void _restartSoon([Duration delay = const Duration(milliseconds: 400)]) {
    _restartTimer?.cancel();
    _isRunning = false;
    _restartTimer = Timer(delay, () {
      if (_isEnabled && !_isPaused && !_handoffInProgress) {
        _startListeningLoop();
      }
    });
  }

  Future<void> _listenOnce() async {
    if (!_isEnabled || _isPaused || !_isInitialized || _speech.isListening) {
      _isRunning = false;
      return;
    }

    try {
      _isRunning = true;
      await _speech.listen(
        onResult: _handleResult,
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
        ),
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 4),
      );
    } catch (e) {
      developer.log('WakeWordService listen failed: $e', name: 'WakeWordService');
      _isRunning = false;
      _restartSoon();
    }
  }

  void _handleResult(SpeechRecognitionResult result) {
    final heard = result.recognizedWords.trim();
    if (heard.isEmpty) return;

    final match = _findWakeMatch(heard);
    if (match != null) {
      _handleWakeWord(match.trailingText);
      _handoffInProgress = true;
      _restartTimer?.cancel();
      _restartTimer = null;
      _isRunning = false;
      _speech.stop();

      Timer(const Duration(seconds: 4), () {
        _handoffInProgress = false;
        if (_isEnabled && !_isPaused && !_speech.isListening) {
          _restartSoon();
        }
      });
      return;
    }

    if (result.finalResult && _isEnabled && !_isPaused && !_handoffInProgress) {
      _restartSoon();
    }
  }

  void _handleWakeWord(String trailingText) {
    final now = DateTime.now();
    if (_lastWakeAt != null && now.difference(_lastWakeAt!).inMilliseconds < 1800) {
      return;
    }
    _lastWakeAt = now;

    developer.log(
      'Wake word detected! Trailing: "$trailingText"',
      name: 'WakeWordService',
    );

    onWakeWord?.call(trailingText);
  }

  static _WakeMatch? _findWakeMatch(String rawText) {
    final normalized = _normalizeForWake(rawText);
    if (normalized.isEmpty) return null;

    for (final pattern in _wakePatterns) {
      final match = pattern.firstMatch(normalized);
      if (match == null) continue;
      final trailing = normalized.substring(match.end).trim();
      return _WakeMatch(match.group(0) ?? _canonicalWakePhrase, trailing);
    }

    return null;
  }

  static String _normalizeForWake(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static final List<RegExp> _wakePatterns = [
    RegExp(
      r'\b(?:hey|hi|okay|ok)\s+(?:nexa|nex a|nex|nixa|neksa|nexus|nexta|next up|next uh|next|alexa|lexa)\b',
      caseSensitive: false,
    ),
    RegExp(
      r'\b(?:nexa|nexus|alexa)\s+(?:wake up|start listening|listen)\b',
      caseSensitive: false,
    ),
  ];

  void dispose() {
    _isEnabled = false;
    _isRunning = false;
    _handoffInProgress = false;
    _restartTimer?.cancel();
    _speech.stop();
    // Don't stop the native foreground service on dispose.
  }
}

class _WakeMatch {
  final String matchedPhrase;
  final String trailingText;

  const _WakeMatch(this.matchedPhrase, this.trailingText);
}
