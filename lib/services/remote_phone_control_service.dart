import 'dart:async';
import 'dart:developer' as developer;
import 'screen_automation_service.dart';
import 'shizuku_service.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import '../models/agent_action.dart';
import 'screenshare_service.dart';

/// Provides remote phone control capabilities via Discord and Telegram bots.
///
/// This service allows authenticated users to:
///   - **See** the phone: take screenshots, get screen descriptions, or
///     start a live screenshare stream
///   - **Control** the phone: tap, type, scroll, press keys, open apps,
///     long-press, double-tap, open notifications/recent apps
///   - **Lock/unlock** the phone screen
///   - **Run commands**: execute shell commands, create/read files
///   - **Stream**: continuous screen feed with auto-snap after actions
class RemotePhoneControlService {
  final ScreenAutomationService _screenService;
  final ShizukuService _shizukuService;
  final ActionHandler _actionHandler;
  final AiService _aiService;
  late final ScreenshareService _screenshare;

  /// Callback to send a message back to the user (Discord embed or Telegram text).
  /// Set by DiscordService / TelegramService before handling commands.
  void Function(String platform, String message)? onMessage;

  RemotePhoneControlService({
    required ScreenAutomationService screenService,
    required ShizukuService shizukuService,
    required ActionHandler actionHandler,
    required AiService aiService,
  }) : _screenService = screenService,
       _shizukuService = shizukuService,
       _actionHandler = actionHandler,
       _aiService = aiService {
    _screenshare = ScreenshareService(
      screenService: _screenService,
    );
  }

  ScreenshareService get screenshare => _screenshare;

  /// Handles a remote command and returns the result.
  /// Commands are in the format: /command [params]
  ///
  /// Available commands:
  ///   /screenshot         — Takes a screenshot (returns base64 JPEG)
  ///   /screen             — Gets the text content of the current screen
  ///   /stream [seconds]   — Start a live screenshare stream (default 3s interval)
  ///   /stopstream         — Stop the screenshare stream
  ///   /tap <text>         — Taps an element by its visible text
  ///   /tap_at <x> <y>     — Taps at specific coordinates
  ///   /long_press <text>  — Long press on an element
  ///   /long_press_at <x> <y> — Long press at coordinates
  ///   /double_tap_at <x> <y> — Double tap at coordinates
  ///   /type <text>        — Types text into the focused input field
  ///   /scroll <direction> — Scrolls up/down/left/right
  ///   /press_back         — Presses the back button
  ///   /press_home         — Presses the home button
  ///   /press_enter        — Presses the enter/search key
  ///   /open <app_name>    — Opens an app
  ///   /notifications      — Opens the notifications shade
  ///   /recent_apps        — Opens the recent apps view
  ///   /lock               — Locks the phone screen
  ///   /unlock             — Wakes and unlocks the phone screen
  ///   /shell <command>    — Runs a shell command
  ///   /run <ai_command>   — Sends a natural language command to AI for execution
  ///   /help               — Shows this help text
  Future<RemoteControlResult> handleCommand(
    String command,
    {String platform = 'discord',
    Future<void> screenshotSender(String base64)?,
    Future<void> screenshareSender(String base64)?,
    void Function(String)? onStreamStopped,
    }
  ) async {
    final parts = command.split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();
    final args = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    developer.log('Remote control command: $cmd, args: $args', name: 'RemotePhoneControl');

    try {
      switch (cmd) {
        // ─── SEE ────────────────────────────────────────────────────────

        case '/screenshot':
          // Don't auto-snap after screenshot — the screenshot itself IS the
          // visual feedback. Auto-snapping would send a duplicate frame.
          return await _takeScreenshot();

        case '/screen':
          // Don't auto-snap after /screen either — the text description is
          // the feedback, and the next periodic frame will show any changes.
          return await _getScreenContent();

        // ─── SCREENSHARE STREAM ──────────────────────────────────────────
        // Note: /stream and /stopstream are intercepted by Discord/Telegram
        // services before reaching handleCommand. This case exists for direct
        // invocation (e.g. via /run AI commands or other call paths).

        case '/stream' || '/screenshare' || '/live':
          final intervalSeconds = int.tryParse(args.split(RegExp(r'\s+')).first) ?? 3;
          if (intervalSeconds < 1 || intervalSeconds > 30) {
            return RemoteControlResult.error('Interval must be 1–30 seconds. Usage: /stream [seconds]');
          }
          if (screenshareSender == null) {
            return RemoteControlResult.error('Screenshare is not available on this platform yet.');
          }
          final description = _screenshare.startStream(
            platform: platform,
            sender: screenshareSender,
            intervalSeconds: intervalSeconds,
            onStopped: onStreamStopped,
          );
          return RemoteControlResult.success(description);

        case '/stopstream' || '/stopscreenshare' || '/stoplive':
          if (!_screenshare.isStreaming(platform)) {
            return RemoteControlResult.success('No screenshare is currently running.');
          }
          _screenshare.stopStream(platform, reason: 'User stopped');
          return RemoteControlResult.success('📺 Screenshare stopped.');

        // ─── CONTROL ────────────────────────────────────────────────────

        case '/tap':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /tap <text to tap>');
          final success = await _screenService.clickByText(args);
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Tapped "$args"' : 'Could not find "$args" to tap',
            isImage: false,
          );

        case '/tap_at':
          final coords = args.split(RegExp(r'\s+'));
          if (coords.length < 2) return RemoteControlResult.error('Usage: /tap_at <x> <y>');
          final x = double.tryParse(coords[0]) ?? 0;
          final y = double.tryParse(coords[1]) ?? 0;
          final success = await _screenService.clickAt(x, y);
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Tapped at ($x, $y)' : 'Tap at ($x, $y) failed',
            isImage: false,
          );

        case '/long_press':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /long_press <text>');
          // First click by text to find the element, then use accessibility
          // for long press. Unfortunately clickByText doesn't give us coords,
          // so we use shell input for a more reliable long press.
          // First find the element coordinates from a screen dump.
          final nodes = await _screenService.dumpScreen();
          double? targetX, targetY;
          for (final node in nodes) {
            final text = (node['text'] ?? node['contentDescription'] ?? '').toString();
            if (text.toLowerCase().contains(args.toLowerCase())) {
              if (node['bounds'] != null) {
                final b = node['bounds'] as Map;
                targetX = ((b['left'] as num) + (b['right'] as num)) / 2;
                targetY = ((b['top'] as num) + (b['bottom'] as num)) / 2;
                break;
              }
            }
          }
          if (targetX == null || targetY == null) {
            return RemoteControlResult.error('Could not find "$args" on screen for long press.');
          }
          // Use accessibility service's long press gesture
          final isRunning = await _screenService.isServiceRunning();
          bool success;
          if (isRunning) {
            success = await _screenService.longPressAt(targetX, targetY);
          } else {
            // Shell fallback: input swipe with long duration simulates long press
            success = true;
            await _shizukuService.runCommand(
              'input swipe ${targetX.round()} ${targetY.round()} ${targetX.round()} ${targetY.round()} 1000',
            );
          }
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Long pressed "$args" at ($targetX, $targetY)' : 'Long press failed',
            isImage: false,
          );

        case '/long_press_at':
          final coords = args.split(RegExp(r'\s+'));
          if (coords.length < 2) return RemoteControlResult.error('Usage: /long_press_at <x> <y>');
          final x = double.tryParse(coords[0]) ?? 0;
          final y = double.tryParse(coords[1]) ?? 0;
          final isRunning = await _screenService.isServiceRunning();
          bool success;
          if (isRunning) {
            success = await _screenService.longPressAt(x, y);
          } else {
            success = true;
            await _shizukuService.runCommand(
              'input swipe ${x.round()} ${y.round()} ${x.round()} ${y.round()} 1000',
            );
          }
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Long pressed at ($x, $y)' : 'Long press failed',
            isImage: false,
          );

        case '/double_tap_at':
          final coords = args.split(RegExp(r'\s+'));
          if (coords.length < 2) return RemoteControlResult.error('Usage: /double_tap_at <x> <y>');
          final x = double.tryParse(coords[0]) ?? 0;
          final y = double.tryParse(coords[1]) ?? 0;
          // Double tap = two rapid taps with a short pause
          final success1 = await _screenService.clickAt(x, y);
          await Future.delayed(const Duration(milliseconds: 100));
          final success2 = await _screenService.clickAt(x, y);
          final success = success1 && success2;
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Double tapped at ($x, $y)' : 'Double tap failed',
            isImage: false,
          );

        case '/type':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /type <text to input>');
          final success = await _screenService.typeText(args);
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Typed "$args"' : 'Could not type text',
            isImage: false,
          );

        case '/scroll':
          final direction = args.isNotEmpty ? args.toLowerCase() : 'down';
          if (direction != 'up' && direction != 'down' && direction != 'left' && direction != 'right') {
            return RemoteControlResult.error('Usage: /scroll up|down|left|right');
          }
          final success = await _screenService.scroll(direction);
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Scrolled $direction' : 'Could not scroll $direction',
            isImage: false,
          );

        case '/swipe':
          final coords = args.split(RegExp(r'\s+'));
          if (coords.length < 4) return RemoteControlResult.error('Usage: /swipe <startX> <startY> <endX> <endY>');
          final startX = double.tryParse(coords[0]) ?? 540;
          final startY = double.tryParse(coords[1]) ?? 1800;
          final endX = double.tryParse(coords[2]) ?? 540;
          final endY = double.tryParse(coords[3]) ?? 500;
          final success = await _screenService.swipe(startX, startY, endX, endY);
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Swiped from ($startX,$startY) to ($endX,$endY)' : 'Swipe failed',
            isImage: false,
          );

        case '/press_back':
          final success = await _screenService.pressBack();
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Pressed back' : 'Could not press back',
            isImage: false,
          );

        case '/press_home':
          final success = await _screenService.pressHome();
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Pressed home' : 'Could not press home',
            isImage: false,
          );

        case '/press_enter':
          final success = await _screenService.pressEnter();
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Pressed enter' : 'Could not press enter',
            isImage: false,
          );

        case '/open':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /open <app_name>');
          final result = await _actionHandler.execute(
            AgentAction(action: 'open_app', params: {'app_name': args}, response: 'Opening $args...'),
            aiService: _aiService,
          );
          // Wait a bit for the app to launch, then auto-snap
          await Future.delayed(const Duration(milliseconds: 1500));
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: result.success,
            details: result.details ?? (result.success ? 'Opened $args' : 'Could not open $args'),
            isImage: false,
          );

        case '/notifications':
          final success = await _screenService.openNotifications();
          await Future.delayed(const Duration(milliseconds: 500));
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: success,
            details: success ? 'Opened notifications' : 'Could not open notifications',
            isImage: false,
          );

        case '/recent_apps':
          final isRunning = await _screenService.isServiceRunning();
          if (isRunning) {
            // Use accessibility service's GLOBAL_ACTION_RECENTS
            final result = await _shizukuService.runCommand('input keyevent KEYCODE_APP_SWITCH');
            await Future.delayed(const Duration(milliseconds: 500));
            _maybeAutoSnap(platform);
            return RemoteControlResult(
              success: true,
              details: 'Opened recent apps',
              isImage: false,
            );
          } else {
            final result = await _shizukuService.runCommand('input keyevent KEYCODE_APP_SWITCH');
            await Future.delayed(const Duration(milliseconds: 500));
            _maybeAutoSnap(platform);
            return RemoteControlResult(
              success: true,
              details: 'Opened recent apps (via shell)',
              isImage: false,
            );
          }

        // ─── LOCK / UNLOCK ──────────────────────────────────────────────

        case '/lock':
          return await _lockScreen(platform);

        case '/unlock':
          return await _unlockScreen(platform);

        // ─── SHELL ──────────────────────────────────────────────────────

        case '/shell':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /shell <command>');
          final result = await _shizukuService.runCommand(args);
          _maybeAutoSnap(platform);
          return RemoteControlResult(
            success: true,
            details: result,
            isImage: false,
          );

        // ─── AI-POWERED COMMAND ─────────────────────────────────────────

        case '/run':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /run <natural language command>');
          final result = await _runAiCommand(args);
          _maybeAutoSnap(platform);
          return result;

        // ─── HELP ────────────────────────────────────────────────────────

        case '/help':
          // No auto-snap needed — help doesn't change the screen
          return RemoteControlResult.success(_getHelpText());

        default:
          // If it doesn't match a /command, try to run it via AI
          if (!cmd.startsWith('/')) {
            return await _runAiCommand(command);
          }
          return RemoteControlResult.error(
            'Unknown command: $cmd\n\n${_getHelpText()}',
          );
      }
    } catch (e) {
      developer.log('Remote control error: $e', name: 'RemotePhoneControl');
      return RemoteControlResult.error('Error: $e');
    }
  }

  // ─── Auto-snap after actions ────────────────────────────────────────

  /// If a screenshare is active for [platform], send an immediate frame
  /// so the user sees the result of their control action right away.
  void _maybeAutoSnap(String platform) {
    if (_screenshare.isStreaming(platform)) {
      _screenshare.requestImmediateFrame(platform);
    }
  }

  // ─── SCREEN CAPTURE ───────────────────────────────────────────────────

  Future<RemoteControlResult> _takeScreenshot() async {
    final screenshotBase64 = await _screenService.takeScreenshot();
    if (screenshotBase64 == null || screenshotBase64.isEmpty) {
      return RemoteControlResult.error('Could not take screenshot. Make sure accessibility service is enabled and Android 11+.');
    }
    return RemoteControlResult(
      success: true,
      details: screenshotBase64,
      isImage: true,
    );
  }

  Future<RemoteControlResult> _getScreenContent() async {
    final content = await _screenService.getScreenDescription();
    if (content.contains('Could not read screen')) {
      return RemoteControlResult.error('Could not read screen. Make sure accessibility service is enabled.');
    }
    return RemoteControlResult.success(content);
  }

  // ─── LOCK / UNLOCK ────────────────────────────────────────────────────

  Future<RemoteControlResult> _lockScreen(String platform) async {
    final result = await _shizukuService.runCommand('input keyevent 26');
    // Also try accessibility service if available
    final isRunning = await _screenService.isServiceRunning();
    if (isRunning) {
      // On API 28+, GLOBAL_ACTION_LOCK_SCREEN is available
      // This is handled by the accessibility service config now having
      // flagRequestDismissKeyguard which also enables lock screen action
    }
    await Future.delayed(const Duration(milliseconds: 500));
    _maybeAutoSnap(platform);
    return RemoteControlResult(
      success: true,
      details: 'Screen locked. (Power button pressed via shell)',
      isImage: false,
    );
  }

  Future<RemoteControlResult> _unlockScreen(String platform) async {
    // 1. Wake the screen by pressing power
    await _shizukuService.runCommand('input keyevent 26');
    await Future.delayed(const Duration(milliseconds: 500));

    // 2. Dismiss keyguard — try accessibility first (more reliable)
    final isRunning = await _screenService.isServiceRunning();
    if (isRunning) {
      // Use accessibility gesture for swipe up unlock (works on most devices)
      await _screenService.swipe(540, 1800, 540, 300);
      await Future.delayed(const Duration(milliseconds: 500));
    } else {
      // Fallback: shell swipe
      await _shizukuService.runCommand('input swipe 540 1800 540 300 500');
    }

    await Future.delayed(const Duration(milliseconds: 500));
    _maybeAutoSnap(platform);

    return RemoteControlResult(
      success: true,
      details: 'Screen unlocked. (Power pressed + swipe up to dismiss keyguard)\nNote: PIN/pattern locks require manual entry unless the device has no secure lock.',
      isImage: false,
    );
  }

  // ─── AI-POWERED COMMAND ───────────────────────────────────────────────

  Future<RemoteControlResult> _runAiCommand(String command) async {
    try {
      final aiResponse = await _aiService.sendMessage(command);
      final action = _aiService.parseAction(aiResponse);

      if (action != null) {
        final result = await _actionHandler.execute(
          action,
          aiService: _aiService,
          onProgress: (msg) {
            developer.log('Remote AI task progress: $msg', name: 'RemotePhoneControl');
          },
        );
        return RemoteControlResult(
          success: result.success,
          details: result.details ?? (result.success ? 'Done.' : 'Task failed.'),
          isImage: false,
        );
      } else {
        return RemoteControlResult.success(aiResponse);
      }
    } catch (e) {
      return RemoteControlResult.error('AI error: $e');
    }
  }

  // ─── HELP TEXT ─────────────────────────────────────────────────────────

  static String _getHelpText() {
    return '''**Nexa Remote Phone Control**

See & control this phone like you're holding it — from anywhere in the world.

**👀 See:**
/screenshot — Take a screenshot (sent as image)
/screen — Read what's currently on screen
/stream [seconds] — Start live screenshare (default 3s interval)
/stopstream — Stop the screenshare

**👆 Control:**
/tap <text> — Tap an element by its visible text
/tap_at <x> <y> — Tap at coordinates
/long_press <text> — Long press an element
/long_press_at <x> <y> — Long press at coordinates
/double_tap_at <x> <y> — Double tap at coordinates
/type <text> — Type text into focused field
/scroll up|down|left|right — Scroll the screen
/swipe <sx> <sy> <ex> <ey> — Custom swipe gesture
/press_back — Press the back button
/press_home — Press the home button
/press_enter — Press enter/search key
/open <app> — Open an app
/notifications — Open notifications shade
/recent_apps — Open recent apps view

**🔒 Lock/Unlock:**
/lock — Lock the phone screen
/unlock — Wake up and unlock the screen

**⚡ Shell:**
/shell <command> — Run a shell command

**🤖 AI Commands:**
/run <what you want> — Natural language, Nexa decides the action
Or just type any command without / prefix — Nexa will handle it.

**💡 Pro tips:**
1. Use /stream to start a live screenshare — see your phone updating in real-time!
2. Control commands auto-snap the screen if a stream is active
3. Use /screenshot for a single snapshot
4. Use /screen for faster text-only view
5. Combine with /run for complex tasks''';
  }
}

/// Result of a remote control command.
class RemoteControlResult {
  final bool success;
  final String details;
  final bool isImage;  // If true, details is base64-encoded JPEG image data

  const RemoteControlResult({
    required this.success,
    required this.details,
    required this.isImage,
  });

  factory RemoteControlResult.success(String details) =>
      RemoteControlResult(success: true, details: details, isImage: false);

  factory RemoteControlResult.error(String details) =>
      RemoteControlResult(success: false, details: details, isImage: false);
}
