import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'action_handler.dart';
import 'ai_service.dart';

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

  String _botToken = '';
  String _channelId = '';
  String _authPassword = '';
  bool _isEnabled = false;

  String? _lastMessageId;
  bool _isPolling = false;
  Timer? _pollingTimer;
  Timer? _typingTimer;

  /// Discord user IDs that have successfully authenticated this session.
  final Set<String> _authenticatedUsers = {};

  DiscordService(this._actionHandler, this._aiService);

  bool get isEnabled => _isEnabled;
  String get botToken => _botToken;
  String get channelId => _channelId;
  String get authPassword => _authPassword;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _botToken = prefs.getString('discord_bot_token') ?? '';
    _channelId = prefs.getString('discord_channel_id') ?? '';
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
  }) async {
    _botToken = botToken;
    _channelId = channelId;
    if (authPassword != null) _authPassword = authPassword;
    _isEnabled = isEnabled;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('discord_bot_token', _botToken);
    await prefs.setString('discord_channel_id', _channelId);
    await prefs.setString('discord_auth_password', _authPassword);
    await prefs.setBool('discord_enabled', _isEnabled);

    if (_isEnabled && _botToken.isNotEmpty && _channelId.isNotEmpty) {
      startPolling();
    } else {
      stopPolling();
    }
  }

  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _bootstrapAndPoll();
  }

  void stopPolling() {
    _isPolling = false;
    _pollingTimer?.cancel();
    _typingTimer?.cancel();
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bot $_botToken',
        'Content-Type': 'application/json',
      };

  /// On first start, jump straight to "now" so we don't reply to the entire
  /// channel history — then begin the normal 3s polling loop.
  Future<void> _bootstrapAndPoll() async {
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
      }
    } catch (e) {
      developer.log('Discord bootstrap failed: $e', name: 'DiscordService');
    }
    _poll();
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
        await Future.delayed(Duration(milliseconds: (retryAfter * 1000).round()));
      } else {
        developer.log(
          'Discord poll error (${response.statusCode}): ${response.body}',
          name: 'DiscordService',
        );
      }
    } catch (e) {
      developer.log('Discord polling error: $e', name: 'DiscordService');
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
      description: 'Control this device straight from Discord.',
      color: _colorAccent,
      fields: [
        {
          'name': '🔐 Authenticate',
          'value': '```!nexa_password <token>```',
          'inline': false,
        },
        {
          'name': '⚡ Run a command',
          'value': '```!nexa <what you want done>```',
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

  void dispose() {
    stopPolling();
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T value) block) => block(this);
}
