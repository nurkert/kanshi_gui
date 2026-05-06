import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Subprocess execution boundary used by the compositor backends. Production
/// code uses [DefaultProcessRunner] which delegates to `dart:io`; tests
/// substitute a fake recorder + canned output so backends can be exercised
/// without touching the host system.
abstract class ProcessRunner {
  /// Default upper bound on how long a single short-lived subprocess (e.g.
  /// `swaymsg`, `wlr-randr`, `kanshictl`) is allowed to run before it is
  /// killed and a synthetic non-zero result is returned. Without this
  /// guard a hung helper would block the apply pipeline indefinitely.
  static const Duration defaultTimeout = Duration(seconds: 5);

  /// Run [executable] with [arguments] and return its [ProcessResult]. If
  /// the process is still running when [timeout] elapses, it is killed
  /// (SIGKILL after a brief SIGTERM grace period) and a synthetic
  /// `ProcessResult(-1, …)` with `stderr = "<exe>: timed out after Ns"`
  /// is returned. The default [timeout] is [defaultTimeout]; pass a
  /// tighter value for fast-path probes.
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = defaultTimeout,
  });

  /// True when [executable] is found in `$PATH` (and is executable). Used by
  /// auto-detection (`command -v` style) without forking a shell.
  Future<bool> exists(String executable);

  /// Spawns a long-running subprocess and exposes its stdout as a line
  /// stream. The stream completes when the process exits. Used to listen
  /// to compositor event subscriptions (e.g. `swaymsg -t subscribe -m`).
  /// Returns a [ProcessStream] handle so the caller can [ProcessStream.kill]
  /// the underlying process when done. Long-running by definition — no
  /// timeout is enforced here.
  ProcessStream stream(String executable, List<String> arguments);
}

/// Handle to a long-running subprocess started via [ProcessRunner.stream].
class ProcessStream {
  final Stream<String> lines;
  final Future<void> Function() kill;
  /// Future that resolves to the OS-level pid once the underlying
  /// `Process.start` completes. Useful for callers (e.g. MirrorRunner)
  /// that need to distinguish their own managed children from
  /// independently-spawned siblings when scanning the live process
  /// table.
  final Future<int?> pid;
  const ProcessStream({
    required this.lines,
    required this.kill,
    required this.pid,
  });
}

class DefaultProcessRunner implements ProcessRunner {
  const DefaultProcessRunner();

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = ProcessRunner.defaultTimeout,
  }) async {
    // Use Process.start (not Process.run) so we own the child handle and
    // can kill it when the timeout fires. Future.timeout alone would
    // resolve our future but leave the child process orphaned.
    final proc = await Process.start(executable, arguments);
    final stdoutChunks = <List<int>>[];
    final stderrChunks = <List<int>>[];
    final stdoutDone = proc.stdout.listen(stdoutChunks.add).asFuture<void>();
    final stderrDone = proc.stderr.listen(stderrChunks.add).asFuture<void>();
    var timedOut = false;
    Timer? timer;
    timer = Timer(timeout, () {
      timedOut = true;
      proc.kill(ProcessSignal.sigterm);
      // SIGKILL after a short grace period, in case the child swallows
      // SIGTERM. The exitCode future resolves once the kernel reaps it.
      Timer(const Duration(milliseconds: 500), () {
        proc.kill(ProcessSignal.sigkill);
      });
    });
    final exit = await proc.exitCode;
    timer.cancel();
    await Future.wait([stdoutDone, stderrDone]);
    final stdoutBytes = stdoutChunks.expand((c) => c).toList();
    final stderrBytes = stderrChunks.expand((c) => c).toList();
    if (timedOut) {
      final secs = timeout.inMilliseconds / 1000;
      final s = secs == secs.roundToDouble()
          ? secs.toInt().toString()
          : secs.toStringAsFixed(1);
      return ProcessResult(
        proc.pid,
        -1,
        utf8.decode(stdoutBytes, allowMalformed: true),
        '$executable: timed out after ${s}s',
      );
    }
    return ProcessResult(
      proc.pid,
      exit,
      utf8.decode(stdoutBytes, allowMalformed: true),
      utf8.decode(stderrBytes, allowMalformed: true),
    );
  }

  @override
  ProcessStream stream(String executable, List<String> arguments) {
    final controller = StreamController<String>();
    final pidCompleter = Completer<int?>();
    Process? proc;
    Process.start(executable, arguments).then((p) {
      proc = p;
      pidCompleter.complete(p.pid);
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
      if (!pidCompleter.isCompleted) pidCompleter.complete(null);
      controller.addError(e, st);
      controller.close();
    });
    return ProcessStream(
      lines: controller.stream,
      kill: () async {
        proc?.kill(ProcessSignal.sigterm);
        await controller.close();
      },
      pid: pidCompleter.future,
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
