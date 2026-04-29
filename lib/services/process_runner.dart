import 'dart:async';
import 'dart:convert';
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

  /// Spawns a long-running subprocess and exposes its stdout as a line
  /// stream. The stream completes when the process exits. Used to listen
  /// to compositor event subscriptions (e.g. `swaymsg -t subscribe -m`).
  /// Returns a [ProcessStream] handle so the caller can [ProcessStream.kill]
  /// the underlying process when done.
  ProcessStream stream(String executable, List<String> arguments);
}

/// Handle to a long-running subprocess started via [ProcessRunner.stream].
class ProcessStream {
  final Stream<String> lines;
  final Future<void> Function() kill;
  const ProcessStream({required this.lines, required this.kill});
}

class DefaultProcessRunner implements ProcessRunner {
  const DefaultProcessRunner();

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) {
    return Process.run(executable, arguments);
  }

  @override
  ProcessStream stream(String executable, List<String> arguments) {
    final controller = StreamController<String>();
    Process? proc;
    Process.start(executable, arguments).then((p) {
      proc = p;
      p.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
            cancelOnError: false,
          );
      p.exitCode.whenComplete(() {
        if (!controller.isClosed) controller.close();
      });
    }).catchError((Object e, StackTrace st) {
      controller.addError(e, st);
      controller.close();
    });
    return ProcessStream(
      lines: controller.stream,
      kill: () async {
        proc?.kill(ProcessSignal.sigterm);
        await controller.close();
      },
    );
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
