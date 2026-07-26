import 'dart:async';
import 'dart:developer' as developer;
import 'screen_automation_service.dart';

/// Manages live screen-share sessions that continuously push screenshot
/// frames to Discord or Telegram at a configurable interval.
///
/// A stream works like a remote desktop — the user sees the phone screen
/// updating in real-time and can issue control commands in between frames.
/// After every control action, an extra screenshot is sent immediately so
/// the user sees the result of their tap/scroll/type right away.
///
/// Multiple streams can run simultaneously (one per platform), each with
/// its own interval and sender callback.
class ScreenshareService {
  final ScreenAutomationService _screenService;

  ScreenshareService({
    required ScreenAutomationService screenService,
  }) : _screenService = screenService;

  /// Active streams keyed by platform (e.g. 'discord', 'telegram').
  final Map<String, _ScreenshareSession> _sessions = {};

  /// Starts a screenshare stream for [platform].
  ///
  /// [sender] is called for each screenshot frame — it receives the
  /// base64-encoded JPEG bytes and must send them to the user (Discord
  /// file upload, Telegram sendPhoto, etc.).
  ///
  /// [intervalSeconds] is how often frames are pushed (default 3s).
  /// [onStopped] is called when the stream stops (user command, error,
  /// or disposal).
  ///
  /// Returns a description string for the user.
  String startStream({
    required String platform,
    required Future<void> sender(String base64Jpeg),
    required int intervalSeconds,
    void Function(String reason)? onStopped,
  }) {
    // Stop any existing stream on this platform first — but suppress the
    // onStopped callback for the OLD stream since it's being replaced,
    // not truly "stopped" by the user. The new stream announcement is
    // sufficient feedback.
    final oldSession = _sessions.remove(platform);
    if (oldSession != null) {
      oldSession.stop(reason: 'Replaced by new stream', suppressCallback: true);
    }

    // Wrap the caller's onStopped callback with cleanup logic that removes
    // this session from our map. This ensures that when the session auto-stops
    // due to failures OR is explicitly stopped, it's always cleaned up.
    void cleanupOnStopped(String reason) {
      _sessions.remove(platform);  // Ensure we're removed from the map
      onStopped?.call(reason);     // Then notify the caller
    }

    final session = _ScreenshareSession(
      platform: platform,
      screenService: _screenService,
      intervalSeconds: intervalSeconds,
      sender: sender,
      onStopped: cleanupOnStopped,
    );

    _sessions[platform] = session;
    session.start();

    developer.log(
      'Screenshare started for $platform, interval=${intervalSeconds}s',
      name: 'ScreenshareService',
    );

    return '📺 Screenshare started! Streaming every ${intervalSeconds}s.\n'
        'Send /stopstream to end the session.\n'
        'Control commands (/tap, /type, etc.) still work and auto-snap the result.';
  }

  /// Stops the screenshare stream for [platform].
  void stopStream(String platform, {String reason = 'User requested'}) {
    final session = _sessions.remove(platform);
    if (session != null) {
      session.stop(reason: reason);
      developer.log(
        'Screenshare stopped for $platform: $reason',
        name: 'ScreenshareService',
      );
    }
  }

  /// Whether a stream is currently running for [platform].
  bool isStreaming(String platform) => _sessions.containsKey(platform);

  /// Returns info about all active streams.
  Map<String, String> activeStreams() {
    return _sessions.map((k, v) => MapEntry(k, v.status()));
  }

  /// Requests an immediate extra frame for [platform].
  /// Called after a control action so the user sees the result.
  void requestImmediateFrame(String platform) {
    final session = _sessions[platform];
    if (session != null) {
      session.sendImmediateFrame();
    }
  }

  /// Stops all streams.
  void stopAll({String reason = 'Service disposed'}) {
    for (final entry in _sessions.entries) {
      entry.value.stop(reason: reason);
    }
    _sessions.clear();
  }

  void dispose() {
    stopAll(reason: 'Service disposed');
  }
}

/// A single screenshare session for one platform.
class _ScreenshareSession {
  final String platform;
  final ScreenAutomationService _screenService;
  final int intervalSeconds;
  final Future<void> Function(String base64Jpeg) sender;
  final void Function(String reason)? onStopped;

  Timer? _timer;
  bool _sendingFrame = false;  // Prevent overlapping sends
  bool _isStopped = false;     // Prevent sends after stop
  int _frameCount = 0;
  int _consecutiveFailures = 0; // Track failures; auto-stop after too many
  static const int _maxConsecutiveFailures = 10;
  DateTime? _startedAt;

  _ScreenshareSession({
    required this.platform,
    required ScreenAutomationService screenService,
    required this.intervalSeconds,
    required this.sender,
    required this.onStopped,
  }) : _screenService = screenService;

  void start() {
    _startedAt = DateTime.now();
    _frameCount = 0;
    _consecutiveFailures = 0;
    _isStopped = false;

    // Send the first frame immediately (fire-and-forget; the guard
    // prevents overlap with the periodic timer).
    _sendFrame();

    // Then send on interval
    _timer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => _sendFrame(),
    );
  }

  /// Stops the session. [suppressCallback] prevents the onStopped callback
  /// from firing — used when a stream is being *replaced* by a new one
  /// rather than genuinely stopped by the user.
  void stop({String reason = 'Stopped', bool suppressCallback = false}) {
    _isStopped = true;
    _timer?.cancel();
    _timer = null;
    if (!suppressCallback) {
      onStopped?.call(reason);
    }
  }

  String status() {
    final duration = _startedAt != null
        ? DateTime.now().difference(_startedAt!)
        : Duration.zero;
    return 'Streaming for ${duration.inMinutes}m, ${_frameCount} frames sent';
  }

  /// Sends an immediate extra frame (e.g. after a control action).
  void sendImmediateFrame() {
    // Don't overlap with a periodic frame, and don't send if stopped
    if (_sendingFrame || _isStopped) return;
    _sendFrame();
  }

  Future<void> _sendFrame() async {
    if (_sendingFrame || _isStopped) return;
    _sendingFrame = true;

    try {
      final screenshot = await _screenService.takeScreenshot();
      // Check again after the async gap — stream may have been stopped
      // while we were waiting for the screenshot.
      if (_isStopped) {
        _sendingFrame = false;
        return;
      }

      if (screenshot == null || screenshot.isEmpty) {
        _consecutiveFailures++;
        developer.log(
          'Screenshare: could not take screenshot for $platform '
          '($_consecutiveFailures/${_maxConsecutiveFailures} consecutive failures)',
          name: 'ScreenshareService',
        );
        if (_consecutiveFailures >= _maxConsecutiveFailures) {
          developer.log(
            'Screenshare: auto-stopping stream for $platform after '
            '${_maxConsecutiveFailures} consecutive failures',
            name: 'ScreenshareService',
          );
          // Auto-stop this session and notify the platform
          _isStopped = true;
          _timer?.cancel();
          _timer = null;
          onStopped?.call('Stream stopped: ${_maxConsecutiveFailures} consecutive screenshot failures. Make sure the accessibility service is enabled.');
          return;
        }
        // Don't stop the stream on a single failure — just skip this frame
        _sendingFrame = false;
        return;
      }

      _consecutiveFailures = 0; // Reset on success
      _frameCount++;
      await sender(screenshot);
    } catch (e) {
      _consecutiveFailures++;
      developer.log(
        'Screenshare error ($platform): $e '
        '($_consecutiveFailures/${_maxConsecutiveFailures} consecutive failures)',
        name: 'ScreenshareService',
      );
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        _sendingFrame = false;
        _isStopped = true;
        _timer?.cancel();
        _timer = null;
        onStopped?.call('Stream stopped: ${_maxConsecutiveFailures} consecutive errors. Try restarting the stream.');
        return;
      }
      // If the sender fails repeatedly, we'll auto-stop after _maxConsecutiveFailures
    } finally {
      _sendingFrame = false;
    }
  }
}
