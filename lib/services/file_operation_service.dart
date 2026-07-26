import 'dart:convert';
import 'shizuku_service.dart';

/// Provides file and directory operations for the Nexa agent —
/// creating, reading, editing, listing, and deleting files directly
/// through shell commands, without needing to open any external app
/// (like Zarchiver) or drive UI automation.
///
/// All operations target paths under `/sdcard/` (or similar accessible
/// directories) since the app's native shell can write there without
/// elevated privileges.
class FileOperationService {
  final ShizukuService _shizuku;

  FileOperationService(this._shizuku);

  // ─── Path safety ────────────────────────────────────────────────────

  /// Ensures the path is within a directory Android's app shell can write
  /// to without root.  Accepts /sdcard/, /storage/emulated/, /tmp/ and
  /// relative paths (which are resolved under /sdcard/NexaAgent/).
  String _normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '/sdcard/NexaAgent';

    // If relative, resolve under /sdcard/NexaAgent/
    if (!trimmed.startsWith('/')) {
      return '/sdcard/NexaAgent/$trimmed';
    }

    // Accept known writable prefixes
    if (trimmed.startsWith('/sdcard/') ||
        trimmed.startsWith('/storage/emulated/') ||
        trimmed.startsWith('/tmp/') ||
        trimmed.startsWith('/data/local/tmp/') ||
        trimmed.startsWith('/home/')) {
      return trimmed;
    }

    // Reject system/protected paths — redirect to /sdcard/NexaAgent/
    return '/sdcard/NexaAgent/${trimmed.substring(1)}';
  }

  /// Shell-escapes a string for safe use in commands.
  String _shellQuote(String value) {
    if (value.isEmpty) return "''";
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  // ─── Create ─────────────────────────────────────────────────────────

  /// Creates a file at [path] with [content].  If the file already exists
  /// it is overwritten.  Parent directories are created automatically.
  Future<FileOperationResult> createFile(String path, String content) async {
    final safePath = _normalizePath(path);
    final parentDir = safePath.substring(0, safePath.lastIndexOf('/'));

    // 1. Ensure parent directory exists
    final mkdirResult = await _shizuku.runCommand(
      'mkdir -p ${_shellQuote(parentDir)}',
      timeout: const Duration(seconds: 10),
    );
    if (!mkdirResult.contains('exited with code 0')) {
      // mkdir might still succeed but the output format may vary
      // Try to verify the directory was created
      final verify = await _shizuku.runCommand(
        'ls -d ${_shellQuote(parentDir)}',
        timeout: const Duration(seconds: 5),
      );
      if (!verify.contains(parentDir.split('/').last)) {
        return FileOperationResult(
          success: false,
          details: 'Could not create parent directory: $mkdirResult',
        );
      }
    }

    // 2. Write the file content using a safe heredoc-style approach
    // Using base64 encoding to safely handle special characters, quotes, and newlines
    final encoded = base64Encode(utf8.encode(content));
    final writeCmd = 'echo ${_shellQuote(encoded)} | base64 -d > ${_shellQuote(safePath)}';
    final writeResult = await _shizuku.runCommand(
      writeCmd,
      timeout: const Duration(seconds: 30),
    );

    // 3. Verify the file was created
    final verifyResult = await _shizuku.runCommand(
      'ls -la ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 5),
    );

    final success = verifyResult.contains(safePath.split('/').last);
    return FileOperationResult(
      success: success,
      details: success
          ? 'Created file: $safePath (${content.length} bytes)'
          : 'Failed to create file: $safePath. Write output: $writeResult',
      path: safePath,
    );
  }

  /// Creates a directory at [path], including any missing parent directories.
  Future<FileOperationResult> createDirectory(String path) async {
    final safePath = _normalizePath(path);
    final result = await _shizuku.runCommand(
      'mkdir -p ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 10),
    );

    final verify = await _shizuku.runCommand(
      'ls -d ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 5),
    );

    final success = verify.contains(safePath.split('/').last) || verify.contains('exited with code 0');
    return FileOperationResult(
      success: success,
      details: success
          ? 'Created directory: $safePath'
          : 'Failed to create directory: $safePath. Output: $result',
      path: safePath,
    );
  }

  // ─── Read ───────────────────────────────────────────────────────────

  /// Reads the content of the file at [path] and returns it as a string.
  Future<FileOperationResult> readFile(String path) async {
    final safePath = _normalizePath(path);
    final result = await _shizuku.runCommand(
      'cat ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 30),
    );

    // Check if the file exists and was readable
    if (result.contains('No such file') || result.contains('No command provided')) {
      return FileOperationResult(
        success: false,
        details: 'File not found: $safePath',
        path: safePath,
      );
    }

    // Extract the actual content from the command output
    // ShizukuService wraps output with "Android shell exited with code X."
    final content = _extractFileContent(result);
    if (content.isEmpty && !result.contains('exited with code 0')) {
      return FileOperationResult(
        success: false,
        details: 'Failed to read file: $safePath. Output: $result',
        path: safePath,
      );
    }

    return FileOperationResult(
      success: true,
      details: content,
      path: safePath,
    );
  }

  // ─── Edit ───────────────────────────────────────────────────────────

  /// Overwrites the file at [path] with [newContent].
  /// This is the simplest and most reliable edit operation — for partial
  /// edits (like changing one line), the agent should first read the file,
  /// then use AI to modify the content, then write it back.
  Future<FileOperationResult> editFile(String path, String newContent) async {
    // editFile is effectively createFile (overwrite) — but we verify the file exists first
    final safePath = _normalizePath(path);

    final existsResult = await _shizuku.runCommand(
      'ls ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 5),
    );

    if (existsResult.contains('No such file')) {
      // File doesn't exist — create it instead
      return createFile(path, newContent);
    }

    // Overwrite the file with new content
    final encoded = base64Encode(utf8.encode(newContent));
    final writeCmd = 'echo ${_shellQuote(encoded)} | base64 -d > ${_shellQuote(safePath)}';
    final writeResult = await _shizuku.runCommand(
      writeCmd,
      timeout: const Duration(seconds: 30),
    );

    return FileOperationResult(
      success: true,
      details: 'Updated file: $safePath (${newContent.length} bytes)',
      path: safePath,
    );
  }

  /// Appends [content] to the end of the file at [path].
  Future<FileOperationResult> appendToFile(String path, String content) async {
    final safePath = _normalizePath(path);

    // Ensure parent directory exists
    final parentDir = safePath.substring(0, safePath.lastIndexOf('/'));
    await _shizuku.runCommand(
      'mkdir -p ${_shellQuote(parentDir)}',
      timeout: const Duration(seconds: 10),
    );

    final encoded = base64Encode(utf8.encode(content));
    final appendCmd = 'echo ${_shellQuote(encoded)} | base64 -d >> ${_shellQuote(safePath)}';
    final result = await _shizuku.runCommand(
      appendCmd,
      timeout: const Duration(seconds: 30),
    );

    return FileOperationResult(
      success: true,
      details: 'Appended to file: $safePath (${content.length} bytes added)',
      path: safePath,
    );
  }

  // ─── List ────────────────────────────────────────────────────────────

  /// Lists files and directories at [path].
  Future<FileOperationResult> listDirectory(String path) async {
    final safePath = _normalizePath(path);
    final result = await _shizuku.runCommand(
      'ls -la ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 10),
    );

    final content = _extractFileContent(result);
    if (content.contains('No such file') || content.isEmpty) {
      return FileOperationResult(
        success: false,
        details: 'Directory not found: $safePath',
        path: safePath,
      );
    }

    return FileOperationResult(
      success: true,
      details: content,
      path: safePath,
    );
  }

  // ─── Delete ─────────────────────────────────────────────────────────

  /// Deletes the file at [path].
  Future<FileOperationResult> deleteFile(String path) async {
    final safePath = _normalizePath(path);
    final result = await _shizuku.runCommand(
      'rm ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 10),
    );

    // Verify deletion
    final verify = await _shizuku.runCommand(
      'ls ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 5),
    );

    final deleted = verify.contains('No such file');
    return FileOperationResult(
      success: deleted,
      details: deleted
          ? 'Deleted file: $safePath'
          : 'Failed to delete file: $safePath',
      path: safePath,
    );
  }

  /// Deletes the directory at [path] and all its contents.
  Future<FileOperationResult> deleteDirectory(String path) async {
    final safePath = _normalizePath(path);
    // Safety check: don't delete system directories
    if (!safePath.startsWith('/sdcard/') && !safePath.startsWith('/storage/emulated/') && !safePath.startsWith('/tmp/')) {
      return FileOperationResult(
        success: false,
        details: 'Cannot delete directory outside safe zones: $safePath',
      );
    }

    final result = await _shizuku.runCommand(
      'rm -rf ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 30),
    );

    // Verify deletion
    final verify = await _shizuku.runCommand(
      'ls -d ${_shellQuote(safePath)}',
      timeout: const Duration(seconds: 5),
    );

    final deleted = verify.contains('No such file');
    return FileOperationResult(
      success: deleted,
      details: deleted
          ? 'Deleted directory: $safePath'
          : 'Failed to delete directory: $safePath',
      path: safePath,
    );
  }

  // ─── Search ─────────────────────────────────────────────────────────

  /// Searches for files matching [pattern] (glob-style) under [directory].
  Future<FileOperationResult> searchFiles(String directory, String pattern) async {
    final safeDir = _normalizePath(directory);
    final result = await _shizuku.runCommand(
      'find ${_shellQuote(safeDir)} -name ${_shellQuote(pattern)} -maxdepth 3',
      timeout: const Duration(seconds: 30),
    );

    final content = _extractFileContent(result);
    if (content.isEmpty || content.contains('No such file')) {
      return FileOperationResult(
        success: true,
        details: 'No files matching "$pattern" found in $safeDir',
        path: safeDir,
      );
    }

    return FileOperationResult(
      success: true,
      details: content,
      path: safeDir,
    );
  }

  // ─── Helpers ────────────────────────────────────────────────────────

  /// Extracts the actual file/directory content from the shell command
  /// output, stripping the ShizukuService wrapper prefix like
  /// "Android shell exited with code 0."
  String _extractFileContent(String rawOutput) {
    // Remove the command execution wrapper
    final lines = rawOutput.split('\n');
    final contentLines = <String>[];
    bool pastWrapper = false;

    for (final line in lines) {
      if (line.contains('exited with code') && !pastWrapper) {
        pastWrapper = true;
        continue;
      }
      if (line.startsWith('Output:') && !pastWrapper) {
        pastWrapper = true;
        continue;
      }
      if (line.startsWith('Command executed with no output') && !pastWrapper) {
        pastWrapper = true;
        continue;
      }
      if (line.startsWith('Note:') || line.startsWith('Error output:')) {
        continue;
      }
      contentLines.add(line);
    }

    return contentLines.join('\n').trim();
  }
}

/// Result of a file/directory operation.
class FileOperationResult {
  final bool success;
  final String details;
  final String? path;

  const FileOperationResult({
    required this.success,
    required this.details,
    this.path,
  });
}
