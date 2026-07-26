import 'package:android_intent_plus/android_intent.dart';
import 'package:shizuku_api/shizuku_api.dart';

class ShizukuService {
  final ShizukuApi _shizuku = ShizukuApi();
  bool _isAvailable = false;
  bool _hasPermission = false;

  bool get isAvailable => _isAvailable;
  bool get hasPermission => _hasPermission;

  /// Check if Shizuku is installed and running
  Future<bool> checkAvailability() async {
    try {
      _isAvailable = await _shizuku.pingBinder() ?? false;
      if (_isAvailable) {
        _hasPermission = await _shizuku.checkPermission() ?? false;
      }
      return _isAvailable;
    } catch (e) {
      _isAvailable = false;
      _hasPermission = false;
      return false;
    }
  }

  /// Request Shizuku permission
  Future<bool> requestPermission() async {
    if (!_isAvailable) return false;
    try {
      _hasPermission = await _shizuku.requestPermission() ?? false;
      return _hasPermission;
    } catch (e) {
      return false;
    }
  }

  /// Run an ADB shell command via Shizuku, falling back to Termux (if
  /// installed) when Shizuku isn't available or doesn't have permission.
  Future<String> runCommand(String command) async {
    if (_isAvailable && !_hasPermission) {
      await requestPermission();
    }

    if (_isAvailable && _hasPermission) {
      try {
        final result = await _shizuku.runCommand(command);
        return result ?? 'Command executed (no output)';
      } catch (e) {
        return 'Error running command via Shizuku: $e';
      }
    }

    // Shizuku isn't usable — try running the command through Termux instead.
    return runTermuxCommand(command);
  }

  /// Run a shell command via Termux's `RUN_COMMAND` intent.
  ///
  /// Requires:
  ///   - Termux installed with "allow external apps" enabled
  ///     (`allow-external-apps=true` in `~/.termux/termux.properties`).
  ///   - The calling app to hold `com.termux.permission.RUN_COMMAND`.
  Future<String> runTermuxCommand(
    String command, {
    List<String>? arguments,
    String workingDirectory = '/data/data/com.termux/files/home',
    bool background = true,
  }) async {
    try {
      final intent = AndroidIntent(
        action: 'com.termux.RUN_COMMAND',
        package: 'com.termux',
        componentName: 'com.termux/com.termux.app.RunCommandService',
        arguments: <String, dynamic>{
          'com.termux.RUN_COMMAND_PATH': '/data/data/com.termux/files/usr/bin/bash',
          'com.termux.RUN_COMMAND_ARGUMENTS': ['-c', command, ...?arguments],
          'com.termux.RUN_COMMAND_WORKDIR': workingDirectory,
          'com.termux.RUN_COMMAND_BACKGROUND': background,
        },
      );
      await intent.launch();
      return 'Command dispatched to Termux: $command';
    } catch (e) {
      return 'Shizuku is unavailable and the Termux fallback failed. '
          'Install Termux, enable "allow-external-apps" in termux.properties, '
          'and grant it the RUN_COMMAND permission. ($e)';
    }
  }

  /// Run a command as root using PRoot inside Termux — useful for
  /// filesystem-level tasks that need root but where a full ADB/Shizuku
  /// session isn't available. Requires Termux + `proot-distro`/`tsu` (or
  /// `su`) to already be installed and root already granted on-device.
  Future<String> runRootCommand(String command) async {
    // Wrap the command so it runs as root via PRoot's `proot` binary
    // (falling back to `su -c` if a rooted PRoot environment isn't set up).
    final wrapped =
        'command -v proot >/dev/null 2>&1 && proot --link2symlink -0 -r / '
        '-b /dev -b /proc -b /sys $command || su -c "$command"';

    return runTermuxCommand(wrapped);
  }

  /// Toggle WiFi via Shizuku
  Future<String> toggleWifi(bool enable) async {
    return runCommand('svc wifi ${enable ? 'enable' : 'disable'}');
  }

  /// Toggle Bluetooth via Shizuku
  Future<String> toggleBluetooth(bool enable) async {
    return runCommand(
      'cmd bluetooth_manager ${enable ? 'enable' : 'disable'}',
    );
  }

  /// Force stop an app
  Future<String> forceStopApp(String packageName) async {
    return runCommand('am force-stop $packageName');
  }

  /// Clear app data
  Future<String> clearAppData(String packageName) async {
    return runCommand('pm clear $packageName');
  }
}
