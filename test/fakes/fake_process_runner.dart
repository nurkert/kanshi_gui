import 'dart:async';
import 'dart:io';

import 'package:kanshi_gui/services/process_runner.dart';

/// In-memory recorder + scripted-response ProcessRunner. Backend tests use
/// it to assert the exact subprocess invocations and to feed canned JSON
/// stdout for parsing tests.
class FakeProcessRunner implements ProcessRunner {
  /// Map from `binary args` (joined) → ProcessResult.
  final Map<String, ProcessResult> responses;

  /// Set of binaries that should report as installed.
  final Set<String> installed;

  /// Default ProcessResult returned when no scripted response matches.
  final ProcessResult fallback;

  /// Recorded invocations in call order.
  final List<List<String>> calls = [];

  FakeProcessRunner({
    Map<String, ProcessResult>? responses,
    Set<String>? installed,
    ProcessResult? fallback,
  })  : responses = responses ?? <String, ProcessResult>{},
        installed = installed ?? <String>{},
        fallback = fallback ?? ProcessResult(0, 0, '', '');

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = ProcessRunner.defaultTimeout,
  }) async {
    final invocation = [executable, ...arguments];
    calls.add(invocation);
    final key = invocation.join(' ');
    return responses[key] ?? fallback;
  }

  @override
  Future<bool> exists(String executable) async => installed.contains(executable);

  /// Per-key streams that tests can push lines into. Key format matches
  /// [run]: `executable arg1 arg2 …` joined by spaces. A closed controller
  /// is replaced on the next access — without this the MirrorRunner's
  /// respawn loop would attach a fresh listener to an already-closed
  /// controller and fire onDone immediately, causing runaway respawns.
  final Map<String, StreamController<String>> _streamControllers = {};

  StreamController<String> openStream(String key) {
    final existing = _streamControllers[key];
    if (existing != null && !existing.isClosed) return existing;
    final fresh = StreamController<String>.broadcast();
    _streamControllers[key] = fresh;
    return fresh;
  }

  /// Sequential pids handed out by `stream()` so tests that exercise
  /// the MirrorRunner's pid-aware logic can correlate kill calls to
  /// specific spawns.
  int _nextPid = 10000;

  @override
  ProcessStream stream(String executable, List<String> arguments) {
    final invocation = [executable, ...arguments];
    calls.add(invocation);
    final key = invocation.join(' ');
    final ctl = openStream(key);
    final pid = _nextPid++;
    return ProcessStream(
      lines: ctl.stream,
      kill: () async {
        if (!ctl.isClosed) await ctl.close();
        // Drop the closed controller so the next [stream] / [openStream]
        // call gets a fresh one, mirroring the way `Process.start` returns
        // a fresh process with its own pipes each time.
        _streamControllers.remove(key);
      },
      pid: Future.value(pid),
    );
  }
}
