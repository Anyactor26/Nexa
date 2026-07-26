import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shizuku_api/shizuku_api.dart';

class ShizukuService {
  static const MethodChannel _nativeChannel = MethodChannel(
    'com.nexa.agent/accessibility',
  );

  final ShizukuApi _shizuku = ShizukuApi();
  bool _isAvailable = false;
  bool _hasPermission = false;

  bool get isAvailable => _isAvailable;
  bool get hasPermission => _hasPermission;

  /// Check if Shizuku is installed/running. This is optional and intentionally
  /// short-timeout so Nexa never depends on Shizuku being reachable (for
  /// example, when Wireless Debugging is unavailable on mobile data).
  Future<bool> checkAvailability() async {
    try {
      final available = await _shizuku
          .pingBinder()
          .timeout(const Duration(seconds: 2));
      _isAvailable = available ?? false;
      if (_isAvailable) {
        final permitted = await _shizuku
            .checkPermission()
            .timeout(const Duration(seconds: 2));
        _hasPermission = permitted ?? false;
      } else {
        _hasPermission = false;
      }
      return _isAvailable;
    } catch (_) {
      _isAvailable = false;
      _hasPermission = false;
      return false;
    }
  }

  /// Request Shizuku permission. This remains optional; commands still run
  /// through Nexa's local Android shell when permission is not available.
  Future<bool> requestPermission() async {
    if (!_isAvailable) return false;
    try {
      final permitted = await _shizuku
          .requestPermission()
          .timeout(const Duration(seconds: 10));
      _hasPermission = permitted ?? false;
      return _hasPermission;
    } catch (_) {
      _hasPermission = false;
      return false;
    }
  }

  /// Run a shell command without requiring Shizuku or Termux.
  ///
  /// Preference order:
  ///   1. Nexa's native Android shell runner (`/system/bin/sh`) as the app UID.
  ///   2. Existing Shizuku permission only if it is already available and the
  ///      app-UID shell failed like a privileged command.
  ///
  /// Nexa does not request Shizuku here and never dispatches to Termux, so this
  /// works on mobile data for normal shell commands and keeps privileged shell
  /// support purely optional.
  Future<String> runCommand(
    String command, {
    Duration timeout = const Duration(seconds: 30),
    bool allowOptionalShizukuFallback = true,
  }) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return 'No command provided.';

    final local = await _runLocalShellResult(trimmed, timeout: timeout);
    if (local.exitCode == 0 ||
        !allowOptionalShizukuFallback ||
        !_isAvailable ||
        !_hasPermission ||
        !_looksLikePrivilegedFailure(local)) {
      return _formatCommandOutput(local, includeNoDependencyTip: local.exitCode != 0);
    }

    try {
      final shizukuOutput = await _shizuku.runCommand(trimmed).timeout(timeout);
      return _formatCommandOutput(
        _ShellCommandResult(
          stdoutText: shizukuOutput ?? '',
          stderrText: '',
          exitCode: 0,
          timedOut: false,
          backendName: 'Shizuku optional fallback',
        ),
      );
    } on TimeoutException {
      return '${_formatCommandOutput(local, includeNoDependencyTip: true)}\n\n'
          'Optional Shizuku fallback timed out after ${timeout.inSeconds}s.';
    } catch (e) {
      return '${_formatCommandOutput(local, includeNoDependencyTip: true)}\n\n'
          'Optional Shizuku fallback also failed: $e';
    }
  }

  /// Runs a command using Android's built-in shell as Nexa's app UID.
  /// This does not need Shizuku, Termux, wireless debugging, or mobile-data
  /// workarounds. Android will still deny operations that require shell/root.
  Future<String> runLocalShellCommand(
    String command, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final result = await _runLocalShellResult(command, timeout: timeout);
    return _formatCommandOutput(result, includeNoDependencyTip: result.exitCode != 0);
  }

  Future<_ShellCommandResult> _runLocalShellResult(
    String command, {
    required Duration timeout,
  }) async {
    // Prefer the native Kotlin runner. It avoids depending on Dart Process
    // support and captures stdout/stderr without blocking the UI thread.
    try {
      final native = await _nativeChannel.invokeMapMethod<String, Object?>(
        'runShellCommand',
        {
          'command': command,
          'timeoutSeconds': timeout.inSeconds.clamp(1, 3600).toInt(),
        },
      ).timeout(timeout + const Duration(seconds: 2));

      if (native != null) {
        return _ShellCommandResult(
          stdoutText: native['stdout']?.toString() ?? '',
          stderrText: native['stderr']?.toString() ?? '',
          exitCode: (native['exitCode'] as num?)?.toInt() ?? 1,
          timedOut: native['timedOut'] == true,
          backendName: 'Android shell',
        );
      }
    } catch (_) {
      // Fall through to Dart Process as a secondary no-dependency runner.
    }

    try {
      final result = await Process.run(
        '/system/bin/sh',
        ['-c', command],
        runInShell: false,
      ).timeout(timeout);

      return _ShellCommandResult(
        stdoutText: result.stdout?.toString() ?? '',
        stderrText: result.stderr?.toString() ?? '',
        exitCode: result.exitCode,
        timedOut: false,
        backendName: 'Android shell',
      );
    } on TimeoutException {
      return _ShellCommandResult(
        stdoutText: '',
        stderrText: 'Timed out after ${timeout.inSeconds}s.',
        exitCode: 124,
        timedOut: true,
        backendName: 'Android shell',
      );
    } catch (e) {
      return _ShellCommandResult(
        stdoutText: '',
        stderrText: 'Unable to start Android shell: $e',
        exitCode: 1,
        timedOut: false,
        backendName: 'Android shell',
      );
    }
  }

  /// Run a command inside a PRoot environment when a `proot` binary/rootfs is
  /// present, otherwise fall back to `su -c` when the device is rooted.
  ///
  /// This path is also Termux-independent. If a PRoot binary happens to live in
  /// Termux's app directory it can be detected, but Nexa does not require or
  /// call Termux APIs.
  Future<String> runProotCommand(
    String command, {
    String rootfs = '/',
    String workingDirectory = '/',
    List<String> binds = const ['/dev', '/proc', '/sys', '/sdcard'],
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return 'No command provided.';

    final normalizedRootfs = rootfs.endsWith('/') && rootfs.length > 1
        ? rootfs.substring(0, rootfs.length - 1)
        : rootfs;
    final rootfsBinSh = normalizedRootfs == '/'
        ? '/bin/sh'
        : '$normalizedRootfs/bin/sh';
    final rootfsUsrBinSh = normalizedRootfs == '/'
        ? '/usr/bin/sh'
        : '$normalizedRootfs/usr/bin/sh';

    final prootFinder = _knownProotPaths
        .map((path) => '[ -x ${_shellQuote(path)} ] && echo ${_shellQuote(path)}')
        .join(' || ');

    final bindArgs = binds
        .where((path) => path.trim().isNotEmpty)
        .map((path) => '-b ${_shellQuote(path)}')
        .join(' ');

    final script = '''
PROOT_BIN=\$(command -v proot 2>/dev/null || $prootFinder || true)
if [ -n "\$PROOT_BIN" ]; then
  PROOT_SHELL=/system/bin/sh
  [ -x ${_shellQuote(rootfsBinSh)} ] && PROOT_SHELL=/bin/sh
  [ -x ${_shellQuote(rootfsUsrBinSh)} ] && PROOT_SHELL=/usr/bin/sh
  exec "\$PROOT_BIN" --link2symlink -0 -r ${_shellQuote(rootfs)} $bindArgs -w ${_shellQuote(workingDirectory)} "\$PROOT_SHELL" -c ${_shellQuote(trimmed)}
fi
if command -v su >/dev/null 2>&1; then
  exec su -c ${_shellQuote(trimmed)}
fi
echo "No PRoot binary or su root access found. Provide a proot binary/rootfs or root access for this command. Nexa itself does not require Shizuku or Termux." >&2
exit 127
''';

    return runCommand(
      script,
      timeout: timeout,
      allowOptionalShizukuFallback: false,
    );
  }

  /// Backward-compatible name used by callers that ask for a "root" command.
  Future<String> runRootCommand(String command) {
    return runProotCommand(command);
  }

  /// Toggle WiFi via the shell. On modern Android this usually needs elevated
  /// shell/root; Nexa will report Android's denial clearly instead of requiring
  /// Termux or Shizuku.
  Future<String> toggleWifi(bool enable) async {
    return runCommand('svc wifi ${enable ? 'enable' : 'disable'}');
  }

  /// Toggle Bluetooth via the shell. May require elevated privileges.
  Future<String> toggleBluetooth(bool enable) async {
    return runCommand(
      'cmd bluetooth_manager ${enable ? 'enable' : 'disable'}',
    );
  }

  /// Force stop an app. Usually requires elevated privileges.
  Future<String> forceStopApp(String packageName) async {
    return runCommand('am force-stop ${_shellQuote(packageName)}');
  }

  /// Clear app data. Usually requires elevated privileges.
  Future<String> clearAppData(String packageName) async {
    return runCommand('pm clear ${_shellQuote(packageName)}');
  }

  static const List<String> _knownProotPaths = [
    '/data/local/tmp/proot',
    '/data/user/0/com.nexa.agent/files/proot',
    '/data/data/com.nexa.agent/files/proot',
    '/data/data/com.termux/files/usr/bin/proot',
    '/data/adb/ksu/bin/proot',
    '/data/adb/magisk/busybox/proot',
    '/system/bin/proot',
    '/system/xbin/proot',
    '/vendor/bin/proot',
  ];

  static bool _looksLikePrivilegedFailure(_ShellCommandResult result) {
    if (result.exitCode == 0) return false;
    final text = '${result.stdoutText}\n${result.stderrText}'.toLowerCase();
    return text.contains('permission denied') ||
        text.contains('not allowed') ||
        text.contains('requires permission') ||
        text.contains('requires android.permission') ||
        text.contains('security exception') ||
        text.contains('java.lang.securityexception') ||
        text.contains('operation not permitted') ||
        text.contains('inaccessible or not found') ||
        text.contains('cmd: failure') ||
        text.contains('killed');
  }

  static String _formatCommandOutput(
    _ShellCommandResult result, {
    bool includeNoDependencyTip = false,
  }) {
    final buffer = StringBuffer();
    final stdoutClean = _decodeIfNeeded(result.stdoutText).trim();
    final stderrClean = _decodeIfNeeded(result.stderrText).trim();

    buffer.write(result.backendName);
    buffer.write(' exited with code ${result.exitCode}');
    if (result.timedOut) buffer.write(' (timed out)');
    buffer.writeln('.');

    if (stdoutClean.isNotEmpty) {
      buffer.writeln('\nOutput:\n$stdoutClean');
    }
    if (stderrClean.isNotEmpty) {
      buffer.writeln('\nError output:\n$stderrClean');
    }
    if (stdoutClean.isEmpty && stderrClean.isEmpty) {
      buffer.writeln('\nCommand executed with no output.');
    }

    if (includeNoDependencyTip) {
      buffer.writeln(
        "\nNote: Nexa ran this with Android's built-in app shell — no Shizuku, "
        'Termux, wireless debugging, or Wi-Fi connection required. Android may '
        "still block commands that require shell/root privileges; use Nexa's "
        'Accessibility automation or root/PRoot for those cases.',
      );
    }

    return buffer.toString().trimRight();
  }

  static String _decodeIfNeeded(String value) {
    // Some Android APIs/plugins may return JSON-escaped strings. Keep normal
    // text untouched, but recover readable output if it was encoded.
    if (value.length < 2) return value;
    final trimmed = value.trim();
    if (!(trimmed.startsWith('"') && trimmed.endsWith('"'))) return value;
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is String ? decoded : value;
    } catch (_) {
      return value;
    }
  }

  static String _shellQuote(String value) {
    if (value.isEmpty) return "''";
    return "'${value.replaceAll("'", "'\\''")}'";
  }
}

class _ShellCommandResult {
  final String stdoutText;
  final String stderrText;
  final int exitCode;
  final bool timedOut;
  final String backendName;

  const _ShellCommandResult({
    required this.stdoutText,
    required this.stderrText,
    required this.exitCode,
    required this.timedOut,
    required this.backendName,
  });
}
