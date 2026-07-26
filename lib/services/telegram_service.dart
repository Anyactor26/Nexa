import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'action_handler.dart';
import 'ai_service.dart';
import 'screen_automation_service.dart';
import 'shizuku_service.dart';
import 'remote_phone_control_service.dart';

class TelegramService {
  final ActionHandler _actionHandler;
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final ShizukuService _shizukuService;
  late final RemotePhoneControlService _remoteControl;

  String _botToken = '';
  String _authPassword = '';
  bool _isEnabled = false;
  int _lastUpdateId = 0;
  bool _isPolling = false;
  Timer? _pollingTimer;

  // Authenticated Telegram chat IDs
  final Set<String> _authenticatedChats = {};

  TelegramService(this._actionHandler, this._aiService) {
    _screenService = _actionHandler.screenAutomation;
    _shizukuService = _actionHandler.shizuku;
    _remoteControl = RemotePhoneControlService(
      screenService: _screenService,
      shizukuService: _shizukuService,
      actionHandler: _actionHandler,
      aiService: _aiService,
    );
  }

  String get botToken => _botToken;
  bool get isEnabled => _isEnabled;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = prefs.getString('telegram_bot_token') ?? '';
    _isEnabled = prefs.getBool('telegram_enabled') ?? false;
    _authPassword = prefs.getString('telegram_auth_password') ?? '';

    if (_isEnabled && _botToken.isNotEmpty) {
      startPolling();
    }
  }

  Future<void> saveSettings({
    required String botToken,
    required bool isEnabled,
    String? authPassword,
  }) async {
    _botToken = botToken;
    _isEnabled = isEnabled;
    if (authPassword != null) _authPassword = authPassword;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('telegram_bot_token', _botToken);
    await prefs.setBool('telegram_enabled', _isEnabled);
    if (authPassword != null) {
      await prefs.setString('telegram_auth_password', _authPassword);
    }

    if (_isEnabled && _botToken.isNotEmpty) {
      startPolling();
    } else {
      stopPolling();
    }
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _pollUpdates();
  }

  void stopPolling() {
    _isPolling = false;
    _pollingTimer?.cancel();
  }

  Future<void> _pollUpdates() async {
    if (!_isPolling || _botToken.isEmpty) return;

    try {
      final url = Uri.parse('https://api.telegram.org/bot$_botToken/getUpdates');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'offset': _lastUpdateId + 1,
          'timeout': 30,
          'allowed_updates': ['message'],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['ok'] == true) {
          final results = data['result'] as List;
          for (final update in results) {
            _lastUpdateId = update['update_id'];
            if (update['message'] != null && update['message']['text'] != null) {
              final text = update['message']['text'];
              final chatId = update['message']['chat']['id'];
              final username = update['message']['chat']['username'] ?? update['message']['chat']['first_name'] ?? 'someone';

              _handleIncomingMessage(chatId.toString(), text, username);
            }
          }
        }
      }
    } catch (e) {
      developer.log('Telegram polling error: $e', name: 'TelegramService');
    }

    if (_isPolling) {
      _pollingTimer = Timer(const Duration(seconds: 1), _pollUpdates);
    }
  }

  Future<void> _handleIncomingMessage(String chatId, String text, String username) async {
    // ─── Authentication ──────────────────────────────────────────────────

    if (text.startsWith('/auth ') || text.startsWith('/password ')) {
      final token = text.split(RegExp(r'\s+')).skip(1).join(' ').trim();
      if (_authPassword.isEmpty) {
        await _sendMessage(chatId, '⚠️ No auth password configured on the device. Set one in Nexa → Settings → Telegram.');
        return;
      }
      if (token == _authPassword) {
        _authenticatedChats.add(chatId);
        await _sendMessage(chatId, '🔓 Access granted! You can now control the phone.\n\nType /help to see all commands.');
      } else {
        await _sendMessage(chatId, '❌ Incorrect password. Try /auth <password>');
      }
      return;
    }

    // ─── Require auth for all other commands ────────────────────────────

    if (_authPassword.isNotEmpty && !_authenticatedChats.contains(chatId)) {
      await _sendMessage(chatId, '🔒 Authentication required. Send /auth <password> first.');
      return;
    }

    // ─── Help ────────────────────────────────────────────────────────────

    if (text == '/help' || text == '/start') {
      await _sendMessage(chatId, _getHelpText());
      return;
    }

    // ─── Status ──────────────────────────────────────────────────────────

    if (text == '/status') {
      await _sendMessage(chatId, '✅ Nexa is online and listening.');
      return;
    }

    // ─── Remote Phone Control ────────────────────────────────────────────

    // Commands starting with / (except /auth, /help, /status) are remote control
    if (text.startsWith('/')) {
      await _handleRemoteControl(chatId, text);
      return;
    }

    // ─── AI Commands (plain text, no / prefix) ────────────────────────────

    await _sendMessage(chatId, '🤖 Received: "$text". Working on it...');

    try {
      final aiResponse = await _aiService.sendMessage(text);
      final action = _aiService.parseAction(aiResponse);

      if (action != null) {
        final result = await _actionHandler.execute(
          action,
          aiService: _aiService,
          onProgress: (msg) {
            _sendMessage(chatId, '⏳ $msg');
          },
        );
        await _sendMessage(chatId, '✅ ${result.details ?? "Done"}');
      } else {
        final reply = aiResponse.length > 4000
            ? '${aiResponse.substring(0, 4000)}…'
            : aiResponse;
        await _sendMessage(chatId, '💬 $reply');
      }
    } catch (e) {
      await _sendMessage(chatId, '❌ Error: $e');
    }
  }

  // ─── Remote Phone Control ──────────────────────────────────────────────

  Future<void> _handleRemoteControl(String chatId, String command) async {
    await _sendMessage(chatId, '📱 Executing: $command...');

    try {
      final result = await _remoteControl.handleCommand(command);

      if (result.isImage && result.success) {
        // Send screenshot as a photo to Telegram
        await _sendPhoto(chatId, result.details, command);
      } else if (result.success) {
        final reply = result.details.length > 4000
            ? '${result.details.substring(0, 4000)}…'
            : result.details;
        await _sendMessage(chatId, '✅ $reply');
      } else {
        await _sendMessage(chatId, '❌ ${result.details}');
      }
    } catch (e) {
      await _sendMessage(chatId, '❌ Remote control error: $e');
    }
  }

  /// Sends a base64-encoded screenshot as a photo to Telegram.
  Future<void> _sendPhoto(String chatId, String base64Data, String commandLabel) async {
    if (_botToken.isEmpty) return;
    try {
      final bytes = base64Decode(base64Data);

      final uri = Uri.parse('https://api.telegram.org/bot$_botToken/sendPhoto');
      final request = http.MultipartRequest('POST', uri);
      request.fields['chat_id'] = chatId;
      request.fields['caption'] = '📸 Screenshot — $commandLabel';
      request.files.add(http.MultipartFile.fromBytes('photo', bytes, filename: 'nexa_screen.png'));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      if (response.statusCode != 200) {
        developer.log('Failed to send Telegram photo (${response.statusCode}): $responseBody', name: 'TelegramService');
        // Fallback: send screen text
        final screenText = await _screenService.getScreenDescription();
        final reply = screenText.length > 4000 ? '${screenText.substring(0, 4000)}…' : screenText;
        await _sendMessage(chatId, '📸 Screenshot upload failed. Screen text:\n\n$reply');
      }
    } catch (e) {
      developer.log('Failed to send Telegram photo: $e', name: 'TelegramService');
      final screenText = await _screenService.getScreenDescription();
      final reply = screenText.length > 4000 ? '${screenText.substring(0, 4000)}…' : screenText;
      await _sendMessage(chatId, '📸 Screenshot upload failed. Screen text:\n\n$reply');
    }
  }

  // ─── Telegram API ──────────────────────────────────────────────────────

  Future<void> _sendMessage(String chatId, String text) async {
    if (_botToken.isEmpty) return;
    try {
      final url = Uri.parse('https://api.telegram.org/bot$_botToken/sendMessage');
      await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id': chatId,
          'text': text,
          'parse_mode': 'Markdown',
        }),
      );
    } catch (e) {
      developer.log('Failed to send telegram message: $e', name: 'TelegramService');
    }
  }

  static String _getHelpText() {
    return '''*🤖 Nexa Remote Phone Control*

See & control this phone like you're holding it — from anywhere.

*🔐 Auth:*
/auth <password> — Authenticate (required first)

*👀 See:*
/screenshot — Take a screenshot (sent as image)
/screen — Read what's on screen

*👆 Control:*
/tap <text> — Tap an element
/tap_at <x> <y> — Tap at coordinates
/type <text> — Type text
/scroll up|down — Scroll
/press_back — Back button
/press_home — Home button
/press_enter — Enter key
/open <app> — Open an app

*🔒 Lock/Unlock:*
/lock — Lock screen
/unlock — Wake & unlock

*⚡ Shell:*
/shell <cmd> — Run shell command

*🤖 AI:*
Just type any command without / — Nexa handles it!
/run <what you want> — Natural language command''';
  }

  void dispose() {
    stopPolling();
  }
}
