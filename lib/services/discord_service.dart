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

/// A slick, Discord-native remote control surface for Nexa.
///
/// The bot polls a single channel every 3 seconds looking for two kinds of
/// messages:
///   • `!nexa_password <token>`  — authenticates the sender against the
///     password configured on-device. Until a user authenticates, their
///     `!nexa` commands are ignored.
///   • `!nexa <command>`         — runs `<command>` through Nexa exactly like
///     typing it into the app, with the result streamed back as a single,
///     continuously-updated rich embed (so the channel doesn't get spammed).
///
/// Every response is a polished embed with Nexa branding, live status
/// colors, a typing indicator, and a footer timestamp — not raw text.
class DiscordService {
  static const String _apiBase = 'https://discord.com/api/v10';

  // Nexa brand palette
  static const int _colorAccent = 0x8B5CF6; // violet — idle / info
  static const int _colorWorking = 0xF5A623; // amber — thinking / running
  static const int _colorSuccess = 0x22C55E; // green — success
  static const int _colorError = 0xEF4444; // red — error
  static const int _colorLocked = 0x64748B; // slate — auth required

  final ActionHandler _actionHandler;
  final AiService _aiService;
  final ScreenAutomationService _screenService;
  final ShizukuService _shizukuService;
  late final RemotePhoneControlService _remoteControl;

  String _botToken = '';
  String _channelId = '';
  String _authPassword = '';
  bool _isEnabled = false;
  String? _lastError;
  DateTime? _lastStartedAt;
  DateTime? _lastPollAt;

  String? _lastMessageId;
  bool _isPolling = false;
  Timer? _pollingTimer;
  Timer? _typingTimer;

  /// Discord user IDs that have successfully authenticated this session.
  final Set<String> _authenticatedUsers = {};

  DiscordService(this._actionHandler, this._aiService) {
    _screenService = _actionHandler.screenAutomation;
    _shizukuService = _actionHandler.shizuku;
    _remoteControl = RemotePhoneControlService(
      screenService: _screenService,
      shizukuService: _shizukuService,
      actionHandler: _actionHandler,
      aiService: _aiService,
    );
  }

  bool get isEnabled => _isEnabled;
  bool get isPolling => _isPolling;
  String get botToken => _botToken;
  String get channelId => _channelId;
  String get authPassword => _authPassword;
  String? get lastError => _lastError;
  DateTime? get lastStartedAt => _lastStartedAt;
  DateTime? get lastPollAt => _lastPollAt;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = _normalizeBotToken(prefs.getString('discord_bot_token') ?? '');
    _channelId = (prefs.getString('discord_channel_id') ?? '').trim();
    _authPassword = prefs.getString('discord_auth_password') ?? '';
    _isEnabled = prefs.getBool('discord_enabled') ?? false;

    if (_isEnabled && _botToken.isNotEmpty && _channelId.isNotEmpty) {
      startPolling();
    }
  }

  Future<void> saveSettings({
    required String botToken,
    required String channelId,
    String? authPassword,
    required bool isEnabled,
    bool autoStart = true,
  }) async {
    _botToken = _normalizeBotToken(botToken);
    _channelId = channelId.trim();
    if (authPassword != null) _authPassword = authPassword;
    _isEnabled = isEnabled;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('discord_bot_token', _botToken);
    await prefs.setString('discord_channel_id', _channelId);
    await prefs.setString('discord_auth_password', _authPassword);
    await prefs.setBool('discord_enabled', _isEnabled);

    if (_isEnabled && autoStart) {
      if (_botToken.isNotEmpty && _channelId.isNotEmpty) {
        startPolling();
      } else {
        _lastError = 'Discord bot token and channel ID are required.';
        stopPolling();
      }
    } else if (!_isEnabled) {
      stopPolling();
    }
  }

  /// Starts the bot immediately and persists the enabled state. Returns false
  /// with [lastError] populated when token/channel validation fails.
  Future<bool> startBot() async {
    _isEnabled = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('discord_enabled', true);
    return _beginPolling(forceRestart: true);
  }

  /// Stops the bot immediately and persists the disabled state by default.
  Future<void> stopBot({bool persist = true}) async {
    _isEnabled = false;
    _lastError = null;
    stopPolling();
    if (persist) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('discord_enabled', false);
    }
  }

  void startPolling({bool forceRestart = false}) {
    unawaited(_beginPolling(forceRestart: forceRestart));
  }

  Future<bool> _beginPolling({bool forceRestart = false}) async {
    _lastError = null;
    _botToken = _normalizeBotToken(_botToken);
    _channelId = _channelId.trim();

    if (_botToken.isEmpty || _channelId.isEmpty) {
      _lastError = 'Discord bot token and channel ID are required.';
      _isPolling = false;
      return false;
    }

    if (_isPolling && !forceRestart) return true;

    _pollingTimer?.cancel();
    _typingTimer?.cancel();
    _isPolling = true;
    _lastStartedAt = DateTime.now();
    return _bootstrapAndPoll();
  }

  void stopPolling() {
    _isPolling = false;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _typingTimer?.cancel();
    _typingTimer = null;
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bot $_botToken',
        'Content-Type': 'application/json',
      };

  /// On first start, jump straight to "now" so we don't reply to the entire
  /// channel history — then begin the normal 3s polling loop.
  Future<bool> _bootstrapAndPoll() async {
    try {
      final response = await http.get(
        Uri.parse('$_apiBase/channels/$_channelId/messages?limit=1'),
        headers: _headers,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;
        if (data.isNotEmpty) {
          _lastMessageId = data.first['id'] as String;
        }
        _lastError = null;
        _lastPollAt = DateTime.now();
        unawaited(_poll());
        return true;
      }

      _lastError = _friendlyDiscordError(response.statusCode, response.body);
      developer.log(
        'Discord bootstrap error (${response.statusCode}): ${response.body}',
        name: 'DiscordService',
      );
      if (_isFatalDiscordStatus(response.statusCode)) {
        stopPolling();
      } else if (_isPolling) {
        _pollingTimer = Timer(const Duration(seconds: 5), _poll);
      }
      return false;
    } catch (e) {
      _lastError = 'Discord bootstrap failed: $e';
      developer.log(_lastError!, name: 'DiscordService');
      if (_isPolling) {
        _pollingTimer = Timer(const Duration(seconds: 5), _poll);
      }
      return false;
    }
  }

  Future<void> _poll() async {
    if (!_isPolling || _botToken.isEmpty || _channelId.isEmpty) return;

    try {
      final query = _lastMessageId != null
          ? '?after=$_lastMessageId&limit=50'
          : '?limit=1';
      final response = await http.get(
        Uri.parse('$_apiBase/channels/$_channelId/messages$query'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        _lastError = null;
        _lastPollAt = DateTime.now();
        final data = jsonDecode(response.body) as List;
        if (data.isNotEmpty) {
          // Discord returns newest → oldest; process chronologically.
          final messages = data.reversed.toList();
          for (final raw in messages) {
            final message = raw as Map<String, dynamic>;
            _lastMessageId = message['id'] as String;
            final author = message['author'] as Map<String, dynamic>?;
            final isBot = author?['bot'] == true;
            if (isBot) continue;

            final content = (message['content'] as String? ?? '').trim();
            final userId = author?['id'] as String? ?? '';
            final username =
                author?['global_name'] as String? ?? author?['username'] as String? ?? 'someone';

            unawaited(_handleIncomingMessage(userId, username, content));
          }
        }
      } else if (response.statusCode == 429) {
        // Rate limited — back off a bit longer next tick.
        final body = jsonDecode(response.body);
        final retryAfter = (body['retry_after'] as num?)?.toDouble() ?? 1.0;
        _lastError = 'Discord rate limited Nexa; retrying in ${retryAfter.toStringAsFixed(1)}s.';
        await Future.delayed(Duration(milliseconds: (retryAfter * 1000).round()));
      } else {
        _lastError = _friendlyDiscordError(response.statusCode, response.body);
        developer.log(
          'Discord poll error (${response.statusCode}): ${response.body}',
          name: 'DiscordService',
        );
        if (_isFatalDiscordStatus(response.statusCode)) {
          stopPolling();
          return;
        }
      }
    } catch (e) {
      _lastError = 'Discord polling error: $e';
      developer.log(_lastError!, name: 'DiscordService');
    }

    if (_isPolling) {
      _pollingTimer = Timer(const Duration(seconds: 3), _poll);
    }
  }

  Future<void> _handleIncomingMessage(
    String userId,
    String username,
    String content,
  ) async {
    if (content.startsWith('!nexa_password')) {
      await _handleAuth(userId, username, content);
      return;
    }

    if (content.startsWith('!nexa_help') || content == '!nexa') {
      await _sendHelp();
      return;
    }

    if (content.startsWith('!nexa_status')) {
      await _sendStatus(username);
      return;
    }

    if (!content.startsWith('!nexa ')) return; // Not for us.

    if (_authPassword.isNotEmpty && !_authenticatedUsers.contains(userId)) {
      await _sendEmbed(_embed(
        title: '🔒 Authentication required',
        description:
            '**$username**, you need to authenticate before running commands.\n\n'
            'Send:\n```\n!nexa_password <your token>\n```',
        color: _colorLocked,
      ));
      return;
    }

    final command = content.substring(6).trim();
    if (command.isEmpty) {
      await _sendHelp();
      return;
    }

    // ─── Remote Phone Control Commands ──────────────────────────────────
    // Commands starting with / are handled by the remote control service
    // which can see and control the phone like a real user.
    if (command.startsWith('/')) {
      await _handleRemoteControl(username, command);
      return;
    }

    await _runCommand(username, command);
  }

  Future<void> _handleAuth(String userId, String username, String content) async {
    final parts = content.split(RegExp(r'\s+'));
    final token = parts.length > 1 ? parts.sublist(1).join(' ').trim() : '';

    if (_authPassword.isEmpty) {
      await _sendEmbed(_embed(
        title: '⚠️ No password configured',
        description:
            'No Discord auth password has been set on the device yet. '
            'Set one in Nexa → Settings → Discord to enable authentication.',
        color: _colorWorking,
      ));
      return;
    }

    if (token == _authPassword) {
      _authenticatedUsers.add(userId);
      await _sendEmbed(_embed(
        title: '🔓 Access granted',
        description: 'Welcome, **$username**. You can now run:\n```\n!nexa <command>\n```',
        color: _colorSuccess,
      ));
    } else {
      await _sendEmbed(_embed(
        title: '❌ Incorrect password',
        description: 'That token didn\'t match. Try again with `!nexa_password <token>`.',
        color: _colorError,
      ));
    }
  }

  Future<void> _sendHelp() async {
    await _sendEmbed(_embed(
      title: '🤖 Nexa Remote Control',
      description: 'Control this device straight from Discord — see and control the phone like a real user.',
      color: _colorAccent,
      fields: [
        {
          'name': '🔐 Authenticate',
          'value': '```!nexa_password <token>```',
          'inline': false,
        },
        {
          'name': '⚡ Run a command (AI)',
          'value': '```!nexa <what you want done>```',
          'inline': false,
        },
        {
          'name': '👀 See the phone',
          'value': '```!nexa /screenshot``` → screenshot image\n```!nexa /screen``` → screen text',
          'inline': false,
        },
        {
          'name': '👆 Control the phone',
          'value': '```!nexa /tap Settings``` /tap_at /type /scroll\n```!nexa /press_back``` /press_home /press_enter\n```!nexa /open YouTube```',
          'inline': false,
        },
        {
          'name': '🔒 Lock / Unlock',
          'value': '```!nexa /lock``` ```!nexa /unlock```',
          'inline': false,
        },
        {
          'name': '⚡ Shell & AI',
          'value': '```!nexa /shell <cmd>``` ```!nexa /run <natural language>```',
          'inline': false,
        },
        {
          'name': '📡 Check status',
          'value': '```!nexa_status```',
          'inline': false,
        },
      ],
    ));
  }

  /// Handles remote control commands (/screenshot, /tap, etc.)
  Future<void> _handleRemoteControl(String username, String command) async {
    _startTypingLoop();

    final messageId = await _sendEmbed(_embed(
      title: '📱 Remote control…',
      description: '**Command:** $command',
      color: _colorWorking,
      fields: [
        {'name': 'Requested by', 'value': username, 'inline': true},
        {'name': 'Status', 'value': '🟡 Executing…', 'inline': true},
      ],
    ));

    try {
      final result = await _remoteControl.handleCommand(command);

      if (result.isImage && result.success) {
        // Send the screenshot as a file attachment to Discord
        await _sendScreenshotAsFile(result.details, command);
        // Delete the "working" embed
        if (messageId != null) {
          await _deleteMessage(messageId);
        }
      } else {
        final finalEmbed = _embed(
          title: result.success ? '✅ Done' : '❌ Failed',
          description: '**Command:** $command',
          color: result.success ? _colorSuccess : _colorError,
          fields: [
            {'name': 'Requested by', 'value': username, 'inline': true},
            {
              'name': 'Result',
              'value': result.details.length > 3800
                  ? '${result.details.substring(0, 3800)}…'
                  : result.details,
              'inline': false,
            },
          ],
        );

        if (messageId != null) {
          await _editEmbed(messageId, finalEmbed);
        } else {
          await _sendEmbed(finalEmbed);
        }
      }
    } catch (e) {
      final errorEmbed = _embed(
        title: '❌ Remote control error',
        description: '**Command:** $command\n\n```${e.toString()}```',
        color: _colorError,
        fields: [
          {'name': 'Requested by', 'value': username, 'inline': true},
        ],
      );
      if (messageId != null) {
        await _editEmbed(messageId, errorEmbed);
      } else {
        await _sendEmbed(errorEmbed);
      }
    } finally {
      _stopTypingLoop();
    }
  }

  /// Sends a base64-encoded screenshot as a file attachment to Discord.
  Future<void> _sendScreenshotAsFile(String base64Data, String commandLabel) async {
    if (_botToken.isEmpty || _channelId.isEmpty) return;
    try {
      final bytes = base64Decode(base64Data);
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-').replaceAll('.', '');
      final filename = 'nexa_screen_$timestamp.png';

      // Discord file upload requires multipart form data
      final uri = Uri.parse('$_apiBase/channels/$_channelId/messages');
      final request = http.MultipartRequest('POST', uri);
      request.headers['Authorization'] = 'Bot $_botToken';
      request.files.add(http.MultipartFile.fromBytes(filename, bytes, filename: filename));
      request.fields['content'] = '📸 **Screenshot requested** — `$commandLabel`';

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      if (response.statusCode != 200 && response.statusCode != 201) {
        developer.log(
          'Failed to send screenshot to Discord (${response.statusCode}): $responseBody',
          name: 'DiscordService',
        );
        // Fallback: send as text embed with truncated base64
        await _sendEmbed(_embed(
          title: '📸 Screenshot',
          description: 'Screenshot taken (${bytes.length} bytes) but file upload failed. Screen text below:',
          color: _colorAccent,
        ));
      }
    } catch (e) {
      developer.log('Failed to send screenshot as file: $e', name: 'DiscordService');
      // Fallback: try sending the screen text description instead
      final screenText = await _screenService.getScreenDescription();
      await _sendEmbed(_embed(
        title: '📸 Screen content (screenshot upload failed)',
        description: screenText.length > 3800 ? '${screenText.substring(0, 3800)}…' : screenText,
        color: _colorWorking,
      ));
    }
  }

  /// Deletes a message from the Discord channel.
  Future<void> _deleteMessage(String messageId) async {
    if (_botToken.isEmpty || _channelId.isEmpty) return;
    try {
      await http.delete(
        Uri.parse('$_apiBase/channels/$_channelId/messages/$messageId'),
        headers: _headers,
      );
    } catch (e) {
      developer.log('Failed to delete Discord message: $e', name: 'DiscordService');
    }
  }

  Future<void> _sendStatus(String username) async {
    await _sendEmbed(_embed(
      title: '📡 Nexa is online',
      description: 'Requested by **$username**',
      color: _colorSuccess,
      fields: [
        {'name': 'Polling interval', 'value': '3s', 'inline': true},
        {
          'name': 'Authenticated users',
          'value': '${_authenticatedUsers.length}',
          'inline': true,
        },
      ],
    ));
  }

  Future<void> _runCommand(String username, String command) async {
    _startTypingLoop();

    // Post the initial "working" embed, then keep editing *this same
    // message* as the task progresses — no channel spam.
    final messageId = await _sendEmbed(_embed(
      title: '⚙️ Working on it…',
      description: '**Command:** $command',
      color: _colorWorking,
      fields: [
        {'name': 'Requested by', 'value': username, 'inline': true},
        {'name': 'Status', 'value': '🟡 Starting…', 'inline': true},
      ],
    ));

    try {
      final aiResponse = await _aiService.sendMessage(command);
      final action = _aiService.parseAction(aiResponse);

      if (action != null) {
        final result = await _actionHandler.execute(
          action,
          aiService: _aiService,
          onProgress: (msg) {
            if (messageId != null) {
              unawaited(_editEmbed(
                messageId,
                _embed(
                  title: '⚙️ Working on it…',
                  description: '**Command:** $command',
                  color: _colorWorking,
                  fields: [
                    {'name': 'Requested by', 'value': username, 'inline': true},
                    {'name': 'Status', 'value': '🟡 $msg', 'inline': false},
                  ],
                ),
              ));
            }
          },
        );

        final finalEmbed = _embed(
          title: result.success ? '✅ Task complete' : '❌ Task failed',
          description: '**Command:** $command',
          color: result.success ? _colorSuccess : _colorError,
          fields: [
            {'name': 'Requested by', 'value': username, 'inline': true},
            {
              'name': 'Result',
              'value': (result.details ?? (result.success ? 'Done.' : 'Unknown error.'))
                  .trim()
                  .let((s) => s.isEmpty ? '_No output_' : s),
              'inline': false,
            },
          ],
        );

        if (messageId != null) {
          await _editEmbed(messageId, finalEmbed);
        } else {
          await _sendEmbed(finalEmbed);
        }
      } else {
        final replyEmbed = _embed(
          title: '💬 Nexa replies',
          description: aiResponse.length > 3800
              ? '${aiResponse.substring(0, 3800)}…'
              : aiResponse,
          color: _colorAccent,
          fields: [
            {'name': 'Requested by', 'value': username, 'inline': true},
          ],
        );
        if (messageId != null) {
          await _editEmbed(messageId, replyEmbed);
        } else {
          await _sendEmbed(replyEmbed);
        }
      }
    } catch (e) {
      final errorEmbed = _embed(
        title: '❌ Something went wrong',
        description: '**Command:** $command\n\n```${e.toString()}```',
        color: _colorError,
        fields: [
          {'name': 'Requested by', 'value': username, 'inline': true},
        ],
      );
      if (messageId != null) {
        await _editEmbed(messageId, errorEmbed);
      } else {
        await _sendEmbed(errorEmbed);
      }
    } finally {
      _stopTypingLoop();
    }
  }

  // ─── Discord API helpers ─────────────────────────────────────────────

  Map<String, dynamic> _embed({
    required String title,
    required String description,
    required int color,
    List<Map<String, dynamic>>? fields,
  }) {
    return {
      'title': title,
      'description': description,
      'color': color,
      if (fields != null) 'fields': fields,
      'footer': {'text': 'Nexa • Private AI Agent'},
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<String?> _sendEmbed(Map<String, dynamic> embed) async {
    if (_botToken.isEmpty || _channelId.isEmpty) return null;
    try {
      final response = await http.post(
        Uri.parse('$_apiBase/channels/$_channelId/messages'),
        headers: _headers,
        body: jsonEncode({
          'embeds': [embed],
        }),
      );
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return data['id'] as String?;
      }
      developer.log(
        'Failed to send Discord message (${response.statusCode}): ${response.body}',
        name: 'DiscordService',
      );
    } catch (e) {
      developer.log('Failed to send Discord embed: $e', name: 'DiscordService');
    }
    return null;
  }

  Future<void> _editEmbed(String messageId, Map<String, dynamic> embed) async {
    if (_botToken.isEmpty || _channelId.isEmpty) return;
    try {
      await http.patch(
        Uri.parse('$_apiBase/channels/$_channelId/messages/$messageId'),
        headers: _headers,
        body: jsonEncode({
          'embeds': [embed],
        }),
      );
    } catch (e) {
      developer.log('Failed to edit Discord embed: $e', name: 'DiscordService');
    }
  }

  void _startTypingLoop() {
    _sendTyping();
    _typingTimer?.cancel();
    _typingTimer = Timer.periodic(const Duration(seconds: 8), (_) => _sendTyping());
  }

  void _stopTypingLoop() {
    _typingTimer?.cancel();
    _typingTimer = null;
  }

  Future<void> _sendTyping() async {
    if (_botToken.isEmpty || _channelId.isEmpty) return;
    try {
      await http.post(
        Uri.parse('$_apiBase/channels/$_channelId/typing'),
        headers: _headers,
      );
    } catch (_) {
      // Non-critical — ignore.
    }
  }

  static String _normalizeBotToken(String token) {
    var cleaned = token.trim();
    if (cleaned.length >= 2 &&
        ((cleaned.startsWith('"') && cleaned.endsWith('"')) ||
            (cleaned.startsWith("'") && cleaned.endsWith("'")))) {
      cleaned = cleaned.substring(1, cleaned.length - 1).trim();
    }
    if (cleaned.toLowerCase().startsWith('bot ')) {
      cleaned = cleaned.substring(4).trim();
    }
    return cleaned;
  }

  static bool _isFatalDiscordStatus(int statusCode) {
    return statusCode == 401 || statusCode == 403 || statusCode == 404;
  }

  static String _friendlyDiscordError(int statusCode, String body) {
    String details = body;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        details = decoded['message']?.toString() ?? body;
      }
    } catch (_) {}

    switch (statusCode) {
      case 401:
        return 'Discord rejected the bot token. Paste only the token value (without a leading "Bot ") and try Start Bot again.';
      case 403:
        return 'Discord denied access to this channel. Invite the bot with Read Message History, View Channel, Send Messages, and Embed Links permissions.';
      case 404:
        return 'Discord channel not found. Check the Channel ID and make sure the bot is in that server/channel.';
      case 429:
        return 'Discord rate limited the bot. Nexa will retry automatically.';
      default:
        return 'Discord error $statusCode: $details';
    }
  }

  void dispose() {
    stopPolling();
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T value) block) => block(this);
}
