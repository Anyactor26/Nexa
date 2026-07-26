class AgentAction {
  final String action;
  final Map<String, dynamic> params;
  final String response;

  AgentAction({
    required this.action,
    required this.params,
    required this.response,
  });

  factory AgentAction.fromJson(Map<String, dynamic> json) {
    return AgentAction(
      action: json['action'] as String? ?? 'general_query',
      params: json['params'] as Map<String, dynamic>? ?? {},
      response: json['response'] as String? ?? '',
    );
  }

  static const List<String> availableActions = [
    'open_app',
    'make_call',
    'send_sms',
    'search_contact',
    'set_alarm',
    'set_volume',
    'set_brightness',
    'read_notifications',
    'read_screen',
    'run_adb_command',
    'run_root_command',
    'general_query',
    // ─── File & Coding Operations (Agent-style, no Zarchiver needed) ───
    'create_file',        // Create/overwrite a file with content
    'create_directory',   // Create a directory (mkdir -p)
    'read_file',          // Read a file's content
    'edit_file',          // Overwrite a file with new content
    'append_file',        // Append content to a file
    'list_directory',     // List files in a directory
    'delete_file',        // Delete a file
    'delete_directory',   // Delete a directory recursively
    // ─── Phone Lock/Unlock ───────────────────────────────────────────────
    'lock_screen',      // Lock the phone screen (power button)
    'unlock_screen',    // Wake and unlock the phone screen
  ];
}
