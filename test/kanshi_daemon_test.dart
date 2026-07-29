import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/kanshi_daemon.dart';

import 'fakes/fake_process_runner.dart';

/// The reload chain used to live twice, verbatim, in two backends — so a fix
/// to one silently left the other behind. It also had no guard around the
/// systemd probe, which throws on a machine without systemd and made the
/// pkill fallback unreachable: the last resort existed but could not be got
/// to.
void main() {
  ProcessResult ok([String out = '']) => ProcessResult(0, 0, out, '');
  ProcessResult fail([String err = '']) => ProcessResult(0, 1, '', err);

  test('prefers kanshictl when kanshi is running and the socket answers',
      () async {
    final runner = FakeProcessRunner(
      installed: {'kanshictl'},
      responses: {
        'pgrep -x kanshi': ok('123'),
        'kanshictl reload': ok(),
      },
    );
    final r = await KanshiDaemon(runner).reload();
    expect(r.exitCode, 0);
    expect(runner.calls.map((c) => c.first), contains('kanshictl'));
    expect(runner.calls.map((c) => c.first), isNot(contains('bash')));
  });

  test('falls through to the systemd unit when kanshictl fails', () async {
    // A kanshi started straight from the sway config has no IPC socket, so
    // `kanshictl reload` fails even though kanshi is very much running.
    final runner = FakeProcessRunner(
      installed: {'kanshictl'},
      responses: {
        'pgrep -x kanshi': ok('123'),
        'kanshictl reload': fail('failed to connect'),
        'systemctl --user is-active --quiet kanshi.service': ok(),
        'systemctl --user restart kanshi.service': ok(),
      },
    );
    final r = await KanshiDaemon(runner).reload();
    expect(r.exitCode, 0);
    expect(
      runner.calls.any((c) => c.length > 2 && c[2] == 'restart'),
      isTrue,
    );
  });

  test('reaches the pkill fallback on a machine without systemd', () async {
    // The probe throws rather than returning non-zero. Before the guard this
    // escaped out of reload() and the fallback was dead code.
    final runner = FakeProcessRunner(
      installed: const {},
      responses: {'pgrep -x kanshi': fail()},
      throwing: {'systemctl --user is-active --quiet kanshi.service'},
    );
    final r = await KanshiDaemon(runner).reload();
    expect(r.exitCode, 0);
    expect(runner.calls.last.first, 'bash');
  });

  group('isRunning', () {
    test('true when pgrep finds the daemon', () async {
      final runner =
          FakeProcessRunner(responses: {'pgrep -x kanshi': ok('123')});
      expect(await KanshiDaemon(runner).isRunning(), isTrue);
    });

    test('false when it does not', () async {
      final runner = FakeProcessRunner(responses: {'pgrep -x kanshi': fail()});
      expect(await KanshiDaemon(runner).isRunning(), isFalse);
    });

    test('null — not false — when pgrep itself is missing', () async {
      // "I cannot tell" must not be rendered as "kanshi is not running": the
      // assurance line would then claim the layout will not come back on a
      // machine where it will.
      final runner =
          FakeProcessRunner(throwing: {'pgrep -x kanshi'});
      expect(await KanshiDaemon(runner).isRunning(), isNull);
    });
  });
}
