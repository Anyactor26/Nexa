import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'screen_automation_service.dart';
import 'shizuku_service.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import '../models/agent_action.dart';

/// Provides remote phone control capabilities via Discord and Telegram bots.
///
/// This service allows authenticated users to:
///   - **See** the phone: take screenshots and get screen descriptions
///   - **Control** the phone: tap, type, scroll, press keys, open apps
///   - **Lock/unlock** the phone screen
///   - **Run commands**: execute shell commands, create/read files
///
/// Think of it as a remote desktop — but through chat messages.
class RemotePhoneControlService {
  final ScreenAutomationService _screenService;
  final ShizukuService _shizukuService;
  final ActionHandler _actionHandler;
  final AiService _aiService;

  RemotePhoneControlService({
    required ScreenAutomationService screenService,
    required ShizukuService shizukuService,
    required ActionHandler actionHandler,
    required AiService aiService,
  }) : _screenService = screenService,
       _shizukuService = shizukuService,
       _actionHandler = actionHandler,
       _aiService = aiService;

  /// Handles a remote command and returns the result as a string.
  /// Commands are in the format: /command [params]
  ///
  /// Available commands:
  ///   /screenshot         — Takes a screenshot (returns base64 image)
  ///   /screen             — Gets the text content of the current screen
  ///   /tap <text>         — Taps an element by its visible text
  ///   /tap_at <x> <y>     — Taps at specific coordinates
  ///   /type <text>        — Types text into the focused input field
  ///   /scroll <direction> — Scrolls up/down
  ///   /press_back         — Presses the back button
  ///   /press_home         — Presses the home button
  ///   /press_enter        — Presses the enter/search key
  ///   /open <app_name>    — Opens an app
  ///   /lock               — Locks the phone screen
  ///   /unlock             — Wakes and unlocks the phone screen
  ///   /shell <command>    — Runs a shell command
  ///   /run <ai_command>   — Sends a natural language command to AI for execution
  Future<RemoteControlResult> handleCommand(String command) async {
    final parts = command.split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();
    final args = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    developer.log('Remote control command: $cmd, args: $args', name: 'RemotePhoneControl');

    try {
      switch (cmd) {
        // ─── SEE ────────────────────────────────────────────────────────

        case '/screenshot':
          return await _takeScreenshot();

        case '/screen':
          return await _getScreenContent();

        // ─── CONTROL ────────────────────────────────────────────────────

        case '/tap':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /tap <text to tap>');
          final success = await _screenService.clickByText(args);
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
          return RemoteControlResult(
            success: success,
            details: success ? 'Tapped at ($x, $y)' : 'Tap at ($x, $y) failed',
            isImage: false,
          );

        case '/type':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /type <text to input>');
          final success = await _screenService.typeText(args);
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
          return RemoteControlResult(
            success: success,
            details: success ? 'Swiped from ($startX,$startY) to ($endX,$endY)' : 'Swipe failed',
            isImage: false,
          );

        case '/press_back':
          final success = await _screenService.pressBack();
          return RemoteControlResult(
            success: success,
            details: success ? 'Pressed back' : 'Could not press back',
            isImage: false,
          );

        case '/press_home':
          final success = await _screenService.pressHome();
          return RemoteControlResult(
            success: success,
            details: success ? 'Pressed home' : 'Could not press home',
            isImage: false,
          );

        case '/press_enter':
          final success = await _screenService.pressEnter();
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
          return RemoteControlResult(
            success: result.success,
            details: result.details ?? (result.success ? 'Opened $args' : 'Could not open $args'),
            isImage: false,
          );

        // ─── LOCK / UNLOCK ──────────────────────────────────────────────

        case '/lock':
          return await _lockScreen();

        case '/unlock':
          return await _unlockScreen();

        // ─── SHELL ──────────────────────────────────────────────────────

        case '/shell':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /shell <command>');
          final result = await _shizukuService.runCommand(args);
          return RemoteControlResult(
            success: true,
            details: result,
            isImage: false,
          );

        // ─── AI-POWERED COMMAND ─────────────────────────────────────────

        case '/run':
          if (args.isEmpty) return RemoteControlResult.error('Usage: /run <natural language command>');
          return await _runAiCommand(args);

        // ─── HELP ────────────────────────────────────────────────────────

        case '/help':
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

  Future<RemoteControlResult> _lockScreen() async {
    // Use shell command to press power button (keyevent 26)
    final result = await _shizukuService.runCommand('input keyevent 26');
    // Also try via accessibility service if available
    final isRunning = await _screenService.isServiceRunning();
    if (isRunning) {
      // On API 28+, the accessibility service can use GLOBAL_ACTION_LOCK_SCREEN
      // But we can't invoke it directly from Dart — we use shell as primary
      // The accessibility service path is handled in the native FG service
    }
    return RemoteControlResult(
      success: true,
      details: 'Screen locked. (Power button pressed via shell)',
      isImage: false,
    );
  }

  Future<RemoteControlResult> _unlockScreen() async {
    // 1. Wake the screen by pressing power
    await _shizukuService.runCommand('input keyevent 26');
    await Future.delayed(const Duration(milliseconds: 500));

    // 2. Swipe up to dismiss keyguard (works on most lock screens)
    final isRunning = await _screenService.isServiceRunning();
    if (isRunning) {
      // Use accessibility gesture for swipe up unlock
      await _screenService.swipe(540, 1800, 540, 300);
      await Future.delayed(const Duration(milliseconds: 500));
    } else {
      // Fallback: shell swipe
      await _shizukuService.runCommand('input swipe 540 1800 540 300 500');
    }

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

**👆 Control:**
/tap <text> — Tap an element by its visible text
/tap_at <x> <y> — Tap at coordinates
/type <text> — Type text into focused field
/scroll up|down — Scroll the screen
/swipe <sx> <sy> <ex> <ey> — Custom swipe gesture
/press_back — Press the back button
/press_home — Press the home button
/press_enter — Press enter/search key
/open <app> — Open an app

**🔒 Lock/Unlock:**
/lock — Lock the phone screen
/unlock — Wake up and unlock the screen

**⚡ Shell:**
/shell <command> — Run a shell command

**🤖 AI Commands:**
/run <what you want> — Natural language, Nexa decides the action
Or just type any command without / prefix — Nexa will handle it.

**💡 Pro tips:**
1. Use /screenshot first to see the screen
2. Then /tap, /type, /scroll to interact
3. Use /screen for faster text-only view
4. Combine with /run for complex tasks''';
  }
}

/// Result of a remote control command.
class RemoteControlResult {
  final bool success;
  final String details;
  final bool isImage;  // If true, details is base64-encoded image data

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
