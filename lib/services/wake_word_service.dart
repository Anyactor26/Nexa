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
  static const String _wakePhrase = 'hey nexa';

  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _isInitialized = false;
  bool _isEnabled = false;
  bool _isRunning = false;
  bool _isPaused = false;

  /// Called (with the words heard *after* the wake phrase, if any) whenever
  /// "Hey Nexa" is detected.
  void Function(String trailingText)? onWakeWord;

  bool get isEnabled => _isEnabled;
  bool get isListening => _isRunning;

  Future<void> init({void Function(String trailingText)? onWakeWord}) async {
    if (onWakeWord != null) this.onWakeWord = onWakeWord;

    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool(prefsKey) ?? false;

    _isInitialized = await _speech.initialize(
      onError: (error) {
        developer.log('WakeWordService error: $error', name: 'WakeWordService');
        // Restart listening after an error if we're still supposed to be on.
        if (_isEnabled && !_isPaused) {
          _restartSoon();
        }
      },
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (_isEnabled && !_isPaused) {
            _restartSoon();
          }
        }
      },
    );

    if (_isEnabled && _isInitialized) {
      _startListeningLoop();
    }
  }

  /// Enable or disable wake word detection. Persists to SharedPreferences.
  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, enabled);

    if (enabled) {
      if (!_isInitialized) {
        _isInitialized = await _speech.initialize();
      }
      _startListeningLoop();
    } else {
      await _stopListeningLoop();
    }
  }

  /// Temporarily pause wake-word listening (e.g. while the app itself is
  /// actively using the microphone for a voice command or a call is active).
  void pause() {
    _isPaused = true;
    _speech.stop();
  }

  /// Resume wake-word listening after [pause].
  void resume() {
    _isPaused = false;
    if (_isEnabled) {
      _startListeningLoop();
    }
  }

  void _startListeningLoop() {
    if (_isRunning || _isPaused || !_isInitialized) return;
    _isRunning = true;
    _listenOnce();
  }

  Future<void> _stopListeningLoop() async {
    _isRunning = false;
    await _speech.stop();
  }

  void _restartSoon() {
    Timer(const Duration(milliseconds: 400), () {
      if (_isEnabled && !_isPaused) {
        _listenOnce();
      }
    });
  }

  Future<void> _listenOnce() async {
    if (!_isEnabled || _isPaused || !_isInitialized) {
      _isRunning = false;
      return;
    }

    try {
      await _speech.listen(
        onResult: _handleResult,
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
        ),
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 5),
      );
    } catch (e) {
      developer.log('WakeWordService listen failed: $e', name: 'WakeWordService');
      _restartSoon();
    }
  }

  void _handleResult(SpeechRecognitionResult result) {
    final heard = result.recognizedWords.toLowerCase().trim();
    if (heard.isEmpty) return;

    if (heard.contains(_wakePhrase)) {
      final idx = heard.indexOf(_wakePhrase);
      final trailing = heard.substring(idx + _wakePhrase.length).trim();

      developer.log('Wake word detected. Trailing: "$trailing"', name: 'WakeWordService');

      // Stop this session immediately so the caller can start a fresh,
      // full-attention listen for the actual command if it wants to.
      _speech.stop();
      onWakeWord?.call(trailing);
    }

    if (result.finalResult && _isEnabled && !_isPaused) {
      _restartSoon();
    }
  }

  void dispose() {
    _isEnabled = false;
    _isRunning = false;
    _speech.stop();
  }
}
