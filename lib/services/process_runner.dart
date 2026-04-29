import 'dart:io';

/// Subprocess execution boundary used by the compositor backends. Production
/// code uses [DefaultProcessRunner] which delegates to `dart:io`; tests
/// substitute a fake recorder + canned output so backends can be exercised
/// without touching the host system.
abstract class ProcessRunner {
  Future<ProcessResult> run(String executable, List<String> arguments);

  /// True when [executable] is found in `$PATH` (and is executable). Used by
  /// auto-detection (`command -v` style) without forking a shell.
  Future<bool> exists(String executable);
}

class DefaultProcessRunner implements ProcessRunner {
  const DefaultProcessRunner();

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) {
    return Process.run(executable, arguments);
  }

  @override
  Future<bool> exists(String executable) async {
    if (executable.startsWith('/')) {
      return File(executable).existsSync();
    }
    final path = Platform.environment['PATH'] ?? '';
    for (final dir in path.split(':')) {
      if (dir.isEmpty) continue;
      // We only check existence; permission errors surface later via run().
      if (File('$dir/$executable').existsSync()) return true;
    }
    return false;
  }
}
