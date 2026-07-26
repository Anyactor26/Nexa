import 'dart:async';
import 'dart:developer' as developer;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Continuously (best-effort) listens for the wake phrase "Hey Nexa" using
/// on-device speech recognition, and fires [onWakeWord] whenever it hears it.
///
/// Android's [speech_to_text] plugin doesn't support a true always-on hotword
/// engine, so this works by repeatedly starting short listening sessions and
/// restarting them as soon as they end — as close to "always listening" as
/// we can get without a dedicated native wake-word engine (e.g. Porcupine).
class WakeWordService {
  static const String prefsKey = 'wake_word_enabled';
  static const String _canonicalWakePhrase = 'hey nexa';

  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isInitialized = false;
  bool _isEnabled = false;
  bool _isRunning = false;
  bool _isPaused = false;
  bool _handoffInProgress = false;
  Timer? _restartTimer;
  DateTime? _lastWakeAt;

  /// Called (with the words heard *after* the wake phrase, if any) whenever
  /// "Hey Nexa" is detected.
  void Function(String trailingText)? onWakeWord;

  bool get isEnabled => _isEnabled;
  bool get isListening => _isRunning;

  Future<void> init({void Function(String trailingText)? onWakeWord}) async {
    if (onWakeWord != null) this.onWakeWord = onWakeWord;

    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(prefsKey) ?? false;

    await _ensureInitialized();

    if (_isEnabled && _isInitialized) {
      _startListeningLoop();
    }
  }

  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;

    _isInitialized = await _speech.initialize(
      onError: (error) {
        developer.log('WakeWordService error: $error', name: 'WakeWordService');
        _isRunning = false;
        // Restart listening after an error if we're still supposed to be on.
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

  /// Enable or disable wake word detection. Persists to SharedPreferences.
  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, enabled);

    if (enabled) {
      await _ensureInitialized();
      _startListeningLoop();
    } else {
      await _stopListeningLoop();
    }
  }

  /// Temporarily pause wake-word listening (e.g. while the app itself is
  /// actively using the microphone for a voice command or a call is active).
  void pause() {
    _isPaused = true;
    _handoffInProgress = false;
    _restartTimer?.cancel();
    _restartTimer = null;
    _isRunning = false;
    _speech.stop();
  }

  /// Resume wake-word listening after [pause].
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
      final now = DateTime.now();
      if (_lastWakeAt != null && now.difference(_lastWakeAt!).inMilliseconds < 1800) {
        return;
      }
      _lastWakeAt = now;
      _handoffInProgress = true;
      _restartTimer?.cancel();
      _restartTimer = null;
      _isRunning = false;

      developer.log(
        'Wake word detected from "$heard" as "${match.matchedPhrase}". '
        'Trailing: "${match.trailingText}"',
        name: 'WakeWordService',
      );

      // Stop this session immediately so the caller can start a fresh,
      // full-attention listen for the actual command if it wants to.
      _speech.stop();
      onWakeWord?.call(match.trailingText);

      // If the caller does not pause/resume the wake listener, recover by
      // allowing normal restarts shortly after the handoff.
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

  /// Speech recognizers often hear "Hey Nexa" as "hey Alexa", "hey Nexus",
  /// "hey next up", etc. Accept those known variants so the app wakes when the
  /// user's intended phrase was Nexa, while still requiring a wake prefix.
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
  }
}

class _WakeMatch {
  final String matchedPhrase;
  final String trailingText;

  const _WakeMatch(this.matchedPhrase, this.trailingText);
}
