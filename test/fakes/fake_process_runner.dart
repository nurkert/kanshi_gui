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
  Future<ProcessResult> run(String executable, List<String> arguments) async {
    final invocation = [executable, ...arguments];
    calls.add(invocation);
    final key = invocation.join(' ');
    return responses[key] ?? fallback;
  }

  @override
  Future<bool> exists(String executable) async => installed.contains(executable);
}
