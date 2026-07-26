import '../models/agent_action.dart';

/// Routes obvious, unambiguous commands straight to a device action using
/// regex matching — completely bypassing the AI API.
///
/// This exists purely to save tokens/latency/cost: things like "call mom",
/// "set volume to 50", "open youtube" don't need an LLM round-trip to figure
/// out what to do. If nothing matches, [route] returns null and the caller
/// should fall back to the normal AI pipeline.
class LocalCommandRouter {
  /// Attempts to match [input] against a set of known command patterns.
  /// Returns an [AgentAction] ready to be passed to `ActionHandler.execute`,
  /// or `null` if the text doesn't look like a simple, obvious command.
  AgentAction? route(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;

    for (final matcher in _matchers) {
      final action = matcher(text);
      if (action != null) return action;
    }
    return null;
  }

  static final List<AgentAction? Function(String)> _matchers = [
    _matchCall,
    _matchSms,
    _matchAlarm,
    _matchVolume,
    _matchBrightness,
    _matchOpenApp,
    _matchCreateFile,
    _matchCreateDirectory,
    _matchReadFile,
    _matchListDirectory,
    _matchRunRootCommand,
    _matchRunCommand,
  ];

  // ─── Call ────────────────────────────────────────────────────────────

  static final RegExp _callRegex = RegExp(
    r'^(?:please\s+)?(?:call|dial|ring|phone)\s+(.+?)\s*(?:for me|please)?$',
    caseSensitive: false,
  );

  static AgentAction? _matchCall(String text) {
    final match = _callRegex.firstMatch(text);
    if (match == null) return null;
    final target = match.group(1)?.trim() ?? '';
    if (target.isEmpty) return null;

    final params = <String, dynamic>{};
    if (_isPhoneNumber(target)) {
      params['phone_number'] = _normalizePhoneNumber(target);
    } else {
      params['contact_name'] = target;
    }

    return AgentAction(
      action: 'make_call',
      params: params,
      response: 'Calling $target...',
    );
  }

  // ─── SMS / Text ──────────────────────────────────────────────────────

  static final RegExp _smsRegex = RegExp(
    r'^(?:please\s+)?(?:text|message|sms)\s+(?:to\s+)?(.+?)\s*(?:saying|that says|:|-|,)\s*(.+)$',
    caseSensitive: false,
  );

  static AgentAction? _matchSms(String text) {
    final match = _smsRegex.firstMatch(text);
    if (match == null) return null;
    final target = match.group(1)?.trim() ?? '';
    final message = match.group(2)?.trim() ?? '';
    if (target.isEmpty || message.isEmpty) return null;

    final params = <String, dynamic>{'message': message};
    if (_isPhoneNumber(target)) {
      params['phone_number'] = _normalizePhoneNumber(target);
    } else {
      params['contact_name'] = target;
    }

    return AgentAction(
      action: 'send_sms',
      params: params,
      response: 'Texting $target: "$message"',
    );
  }

  // ─── Alarm ───────────────────────────────────────────────────────────

  static final RegExp _alarmRegex = RegExp(
    r'^(?:please\s+)?set\s+(?:an?\s+)?alarm\s+(?:for\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?'
    r'(?:\s*(?:called|named|labeled|for)\s+(.+))?$',
    caseSensitive: false,
  );

  static AgentAction? _matchAlarm(String text) {
    final match = _alarmRegex.firstMatch(text);
    if (match == null) return null;

    int hour = int.tryParse(match.group(1) ?? '') ?? -1;
    final minute = int.tryParse(match.group(2) ?? '0') ?? 0;
    final meridiem = match.group(3)?.toLowerCase();
    final label = match.group(4)?.trim();

    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;

    if (meridiem == 'pm' && hour < 12) hour += 12;
    if (meridiem == 'am' && hour == 12) hour = 0;

    final params = <String, dynamic>{
      'hour': hour,
      'minute': minute,
      if (label != null && label.isNotEmpty) 'label': label,
    };

    final timeStr =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

    return AgentAction(
      action: 'set_alarm',
      params: params,
      response: 'Setting an alarm for $timeStr${label != null ? ' ($label)' : ''}...',
    );
  }

  // ─── Volume ──────────────────────────────────────────────────────────

  static final RegExp _volumeRegex = RegExp(
    r'^(?:please\s+)?(?:set\s+)?(?:the\s+)?volume\s+(?:to\s+)?(\d{1,3})\s*%?$',
    caseSensitive: false,
  );

  static AgentAction? _matchVolume(String text) {
    final match = _volumeRegex.firstMatch(text);
    if (match == null) return null;
    final level = (int.tryParse(match.group(1) ?? '') ?? -1).clamp(0, 100);
    return AgentAction(
      action: 'set_volume',
      params: {'level': level},
      response: 'Setting volume to $level%...',
    );
  }

  // ─── Brightness ──────────────────────────────────────────────────────

  static final RegExp _brightnessRegex = RegExp(
    r'^(?:please\s+)?(?:set\s+)?(?:the\s+)?brightness\s+(?:to\s+)?(\d{1,3})\s*%?$',
    caseSensitive: false,
  );

  static AgentAction? _matchBrightness(String text) {
    final match = _brightnessRegex.firstMatch(text);
    if (match == null) return null;
    final level = (int.tryParse(match.group(1) ?? '') ?? -1).clamp(0, 100);
    return AgentAction(
      action: 'set_brightness',
      params: {'level': level},
      response: 'Setting brightness to $level%...',
    );
  }

  // ─── Open app ────────────────────────────────────────────────────────

  static final RegExp _openAppRegex = RegExp(
    r'^(?:please\s+)?(?:open|launch|start)\s+(?:the\s+)?(?:app\s+)?(.+?)(?:\s+app)?$',
    caseSensitive: false,
  );

  // Words that mean this is NOT a "just open the app" request — leave those
  // to the AI/execute_task pipeline since they imply multiple steps.
  static const List<String> _multiStepHints = [
    ' and ',
    ' then ',
    ' search ',
    ' send ',
    ' find ',
    ' type ',
    ' write ',
    ' create ',
    ' navigate',
    ' go to ',
  ];

  static AgentAction? _matchOpenApp(String text) {
    final lower = text.toLowerCase();
    for (final hint in _multiStepHints) {
      if (lower.contains(hint)) return null;
    }

    final match = _openAppRegex.firstMatch(text);
    if (match == null) return null;
    final appName = match.group(1)?.trim() ?? '';
    if (appName.isEmpty) return null;

    return AgentAction(
      action: 'open_app',
      params: {'app_name': appName},
      response: 'Opening $appName...',
    );
  }

  // ─── File & Coding Operations ───────────────────────────────────────

  // "create a file called X with content Y" / "write a file X containing Y"
  static final RegExp _createFileRegex = RegExp(
    r'^(?:please\s+)?(?:create|make|write)\s+(?:a\s+)?(?:file|script)\s+(?:called|named|at|to|in)?\s*"?([^"]+)"?\s+(?:with|containing|that\s+contains|that\s+has)\s+(.+)$',
    caseSensitive: false,
  );

  static final RegExp _createFileSimpleRegex = RegExp(
    r'^(?:please\s+)?(?:create|make|write)\s+(?:a\s+)?(?:file|script)\s+(?:called|named|at|to|in)?\s*"?([^"]+)"?$',
    caseSensitive: false,
  );

  static AgentAction? _matchCreateFile(String text) {
    // Match "create a file called X with content Y"
    final match = _createFileRegex.firstMatch(text);
    if (match != null) {
      final path = match.group(1)?.trim() ?? '';
      final content = match.group(2)?.trim() ?? '';
      if (path.isEmpty) return null;
      return AgentAction(
        action: 'create_file',
        params: {'path': path, 'content': content},
        response: 'Creating file $path…',
      );
    }

    // Match "create a file called X" (no content — will need AI to fill it)
    final simpleMatch = _createFileSimpleRegex.firstMatch(text);
    if (simpleMatch != null) {
      final path = simpleMatch.group(1)?.trim() ?? '';
      if (path.isEmpty) return null;
      // If the command doesn't include content, let the AI fill it
      return null; // Fall through to AI so it can generate the content
    }

    return null;
  }

  static final RegExp _createDirRegex = RegExp(
    r'^(?:please\s+)?(?:create|make)\s+(?:a\s+)?(?:folder|directory|dir)\s+(?:called|named|at|to|in)?\s*"?([^"]+)"?$',
    caseSensitive: false,
  );

  static AgentAction? _matchCreateDirectory(String text) {
    final match = _createDirRegex.firstMatch(text);
    if (match == null) return null;
    final path = match.group(1)?.trim() ?? '';
    if (path.isEmpty) return null;

    return AgentAction(
      action: 'create_directory',
      params: {'path': path},
      response: 'Creating directory $path…',
    );
  }

  static final RegExp _readFileRegex = RegExp(
    r'^(?:please\s+)?(?:read|show|display|open|view|cat)\s+(?:the\s+)?(?:file|contents\s+of|content\s+of)?\s*"?([^"]+)"?$',
    caseSensitive: false,
  );

  static AgentAction? _matchReadFile(String text) {
    final match = _readFileRegex.firstMatch(text);
    if (match == null) return null;
    final path = match.group(1)?.trim() ?? '';
    if (path.isEmpty) return null;

    // Only match if the path looks like a file path (contains / or known extension)
    if (!path.contains('/') && !_hasKnownExtension(path)) return null;

    return AgentAction(
      action: 'read_file',
      params: {'path': path},
      response: 'Reading file $path…',
    );
  }

  static bool _hasKnownExtension(String path) {
    final extensions = ['.py', '.js', '.ts', '.html', '.css', '.json', '.xml',
      '.yaml', '.yml', '.txt', '.md', '.sh', '.java', '.kt', '.c', '.cpp',
      '.h', '.rb', '.go', '.rs', '.swift', '.dart', '.sql', '.env', '.cfg',
      '.ini', '.toml', '.csv'];
    return extensions.any((ext) => path.toLowerCase().endsWith(ext));
  }

  static final RegExp _listDirRegex = RegExp(
    r'^(?:please\s+)?(?:list|show|ls)\s+(?:the\s+)?(?:files|contents|items)\s+(?:in|of|at)\s*"?([^"]+)"?$',
    caseSensitive: false,
  );

  static AgentAction? _matchListDirectory(String text) {
    final match = _listDirRegex.firstMatch(text);
    if (match == null) return null;
    final path = match.group(1)?.trim() ?? '';
    if (path.isEmpty) return null;

    return AgentAction(
      action: 'list_directory',
      params: {'path': path},
      response: 'Listing directory $path…',
    );
  }

  // ─── Run command (ADB / shell via Shizuku or local Android shell) ───

  static final RegExp _runRootCommandRegex = RegExp(
    r'^(?:please\s+)?(?:run|execute)\s+(?:the\s+)?(?:root|proot|p-root)\s+(?:command|shell command)\s*[:]?\s*(.+)$',
    caseSensitive: false,
  );

  static AgentAction? _matchRunRootCommand(String text) {
    final match = _runRootCommandRegex.firstMatch(text);
    if (match == null) return null;
    final command = match.group(1)?.trim() ?? '';
    if (command.isEmpty) return null;

    return AgentAction(
      action: 'run_root_command',
      params: {'command': command},
      response: 'Running root/PRoot command: $command',
    );
  }

  static final RegExp _runCommandRegex = RegExp(
    r'^(?:please\s+)?(?:run|execute)\s+(?:the\s+)?(?:command|shell command|adb command)\s*[:]?\s*(.+)$',
    caseSensitive: false,
  );

  static AgentAction? _matchRunCommand(String text) {
    final match = _runCommandRegex.firstMatch(text);
    if (match == null) return null;
    final command = match.group(1)?.trim() ?? '';
    if (command.isEmpty) return null;

    return AgentAction(
      action: 'run_adb_command',
      params: {'command': command},
      response: 'Running command: $command',
    );
  }

  // ─── Helpers ─────────────────────────────────────────────────────────

  static final RegExp _phoneNumberRegex = RegExp(r'^[\d\s+()\-.]{5,}$');

  static bool _isPhoneNumber(String value) {
    return _phoneNumberRegex.hasMatch(value.trim());
  }

  static String _normalizePhoneNumber(String value) {
    return value.replaceAll(RegExp(r'[\s()\-.]'), '');
  }
}
