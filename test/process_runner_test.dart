import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/process_runner.dart';

void main() {
  group('DefaultProcessRunner.run', () {
    final runner = const DefaultProcessRunner();

    test('returns the real exit code and stdout for a quick command', () async {
      // `printf hi` exists on every POSIX system Flutter Linux runs on.
      final r = await runner.run('printf', ['hi']);
      expect(r.exitCode, 0);
      expect(r.stdout, 'hi');
      expect(r.stderr, '');
    });

    test('captures stderr separately from stdout', () async {
      // /bin/sh is universally available; emit one line on each stream.
      final r = await runner.run('sh', ['-c', 'echo out; echo err 1>&2']);
      expect(r.exitCode, 0);
      expect((r.stdout as String).trim(), 'out');
      expect((r.stderr as String).trim(), 'err');
    });

    test('preserves a non-zero exit code from the child', () async {
      final r = await runner.run('sh', ['-c', 'exit 7']);
      expect(r.exitCode, 7);
    });

    test('returns a synthetic timeout result and reaps the child', () async {
      final sw = Stopwatch()..start();
      final r = await runner.run(
        'sleep',
        ['10'],
        timeout: const Duration(milliseconds: 300),
      );
      sw.stop();
      // The timeout fires at 300ms; after the SIGTERM grace window
      // (500ms) the kernel will reap. Allow a generous upper bound for
      // CI scheduling jitter.
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)),
          reason: 'sleep 10 should be killed long before its 10s window.');
      expect(r.exitCode, isNot(0),
          reason: 'A timed-out process must surface a non-zero exit.');
      expect(r.stderr, contains('timed out'),
          reason: 'Synthetic stderr should explain the timeout to callers.');
      expect(r.stderr, contains('sleep'),
          reason: 'The stderr should name which executable timed out.');
    });

    test('formats fractional timeouts with one decimal place', () async {
      final r = await runner.run(
        'sleep',
        ['10'],
        timeout: const Duration(milliseconds: 250),
      );
      // 250ms → toStringAsFixed(1) → "0.3"; we just care that the
      // message reads as a fractional second, not as "0s".
      expect(r.stderr, matches(RegExp(r'timed out after 0\.\ds')),
          reason: 'Sub-second timeouts should be formatted with one decimal.');
    });

    test('does not leak the timeout timer when the child exits early',
        () async {
      // If the timer were not cancelled when the child exits in time,
      // `flutter test` would hang waiting for pending timers. The fact
      // that this test completes proves the cancel path runs.
      for (var i = 0; i < 3; i++) {
        final r = await runner.run('true', const []);
        expect(r.exitCode, 0);
      }
    });
  });

  group('DefaultProcessRunner.exists', () {
    final runner = const DefaultProcessRunner();

    test('returns true for a binary that is on PATH', () async {
      // `sh` is on every POSIX system; the test infra is one of those.
      expect(await runner.exists('sh'), isTrue);
    });

    test('returns false for an obvious non-existent name', () async {
      expect(
        await runner.exists('this-binary-cannot-possibly-exist-3d8f72'),
        isFalse,
      );
    });

    test('absolute paths are checked directly', () async {
      // /bin/sh exists on Linux test runners.
      final shExists = File('/bin/sh').existsSync();
      expect(await runner.exists('/bin/sh'), shExists);
    });
  });
}
