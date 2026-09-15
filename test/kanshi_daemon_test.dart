import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/kanshi_daemon.dart';
import 'package:kanshi_gui/services/process_runner.dart';

import 'fakes/fake_process_runner.dart';

/// A process table in which kanshi is there for the first look and gone for
/// every look after — kanshi 1.1 or 1.2, which has no SIGHUP handler and is
/// ended by the signal the reload chain sends.
class _DiesOnHangUp extends FakeProcessRunner {
  _DiesOnHangUp({super.responses});

  int _pgreps = 0;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = ProcessRunner.defaultTimeout,
  }) {
    if (executable == 'pgrep') {
      calls.add([executable, ...arguments]);
      _pgreps++;
      return Future.value(ProcessResult(0, _pgreps == 1 ? 0 : 1, '', ''));
    }
    return super.run(executable, arguments, timeout: timeout);
  }
}

/// The reload chain used to live twice, verbatim, in two backends — so a fix
/// to one silently left the other behind. It also had no guard around the
/// systemd probe, which throws on a machine without systemd and made the
/// pkill fallback unreachable: the last resort existed but could not be got
/// to.
void main() {
  ProcessResult ok([String out = '']) => ProcessResult(0, 0, out, '');
  ProcessResult fail([String err = '']) => ProcessResult(0, 1, '', err);

  const hangUp = ['pkill', '-HUP', '-x', 'kanshi'];

  KanshiDaemon daemon(FakeProcessRunner runner, {String? configPath}) =>
      KanshiDaemon(runner,
          configPath: configPath, hangUpSettle: Duration.zero);

  test('prefers kanshictl when kanshi is running and the socket answers',
      () async {
    final runner = FakeProcessRunner(
      installed: {'kanshictl'},
      responses: {
        'pgrep -x kanshi': ok('123'),
        'kanshictl reload': ok(),
      },
    );
    final r = await daemon(runner).reload();
    expect(r.exitCode, 0);
    expect(runner.calls.map((c) => c.first), contains('kanshictl'));
    expect(runner.calls.map((c) => c.first), isNot(contains('bash')));
    expect(runner.calls.map((c) => c.first), isNot(contains('pkill')));
  });

  test('falls through to the systemd unit when kanshictl cannot connect',
      () async {
    // The message kanshictl 1.3 to 1.9 prints when the socket is not there.
    final runner = FakeProcessRunner(
      installed: {'kanshictl'},
      responses: {
        'pgrep -x kanshi': ok('123'),
        'kanshictl reload': fail(
            "Couldn't connect to kanshi at /run/user/1000/fr.emersion.kanshi.wayland-1.\n"
            'Is the kanshi daemon running?'),
        'systemctl --user is-active --quiet kanshi.service': ok(),
        'systemctl --user restart kanshi.service': ok(),
      },
    );
    final r = await daemon(runner).reload();
    expect(r.exitCode, 0);
    expect(
      runner.calls.any((c) => c.length > 2 && c[2] == 'restart'),
      isTrue,
    );
    expect(runner.calls, isNot(anyElement(equals(hangUp))));
  });

  test('a running kanshi without kanshictl or a unit gets a hang-up, not a '
      'restart', () async {
    // Debian bookworm: kanshi 1.3 built without kanshictl, started from the
    // sway config. SIGHUP is its reload; killing it would flicker every
    // screen for nothing.
    final runner = FakeProcessRunner(
      responses: {
        'pgrep -x kanshi': ok('123'),
        'systemctl --user is-active --quiet kanshi.service':
            ProcessResult(0, 3, '', ''),
        'pkill -HUP -x kanshi': ok(),
      },
    );
    final r = await daemon(runner).reload();
    expect(r.exitCode, 0);
    expect(runner.calls, anyElement(equals(hangUp)));
    expect(runner.calls.map((c) => c.first), isNot(contains('bash')));
  });

  test('a kanshi the hang-up ended is started again', () async {
    // kanshi before 1.3 has no SIGHUP handler; the signal's default action
    // ends it. The chain must notice and end up where it always did.
    final runner = _DiesOnHangUp(
      responses: {
        'systemctl --user is-active --quiet kanshi.service':
            ProcessResult(0, 3, '', ''),
        'pkill -HUP -x kanshi': ok(),
      },
    );
    await daemon(runner).reload();
    expect(runner.calls, anyElement(equals(hangUp)));
    expect(runner.calls.last.first, 'bash');
    expect(runner.calls.last.last, contains('setsid kanshi'));
  });

  test('kanshictl and the hang-up are both skipped when kanshi is not running',
      () async {
    final runner = FakeProcessRunner(
      installed: {'kanshictl'},
      responses: {
        'pgrep -x kanshi': fail(),
        'systemctl --user is-active --quiet kanshi.service':
            ProcessResult(0, 3, '', ''),
      },
    );
    await daemon(runner).reload();
    expect(runner.calls.map((c) => c.first), isNot(contains('kanshictl')));
    expect(runner.calls, isNot(anyElement(equals(hangUp))));
    expect(runner.calls.last.first, 'bash');
  });

  test('reaches the pkill fallback on a machine without systemd', () async {
    // The probe throws rather than returning non-zero. Before the guard this
    // escaped out of reload() and the fallback was dead code.
    final runner = FakeProcessRunner(
      installed: const {},
      responses: {'pgrep -x kanshi': fail()},
      throwing: {'systemctl --user is-active --quiet kanshi.service'},
    );
    final r = await daemon(runner).reload();
    expect(r.exitCode, 0);
    expect(runner.calls.last.first, 'bash');
  });

  group('start', () {
    test('starts kanshi detached and stops nothing', () async {
      final runner = FakeProcessRunner();
      await daemon(runner).start();
      expect(runner.calls, hasLength(1));
      expect(runner.calls.single.first, 'bash');
      final script = runner.calls.single.last;
      expect(script, contains('setsid kanshi -c "\$HOME/.config/kanshi/config"'));
      expect(script, isNot(contains('pkill')));
    });

    test('a config path a shell could misread is refused, not quoted',
        () async {
      final runner = FakeProcessRunner();
      final r =
          await daemon(runner, configPath: r'/tmp/x"; rm -rf ~; "').start();
      expect(r.exitCode, isNot(0));
      expect(runner.calls, isEmpty);
    });
  });

  group('isRunning', () {
    test('true when pgrep finds the daemon', () async {
      final runner =
          FakeProcessRunner(responses: {'pgrep -x kanshi': ok('123')});
      expect(await daemon(runner).isRunning(), isTrue);
    });

    test('false when it does not', () async {
      final runner = FakeProcessRunner(responses: {'pgrep -x kanshi': fail()});
      expect(await daemon(runner).isRunning(), isFalse);
    });

    test('null — not false — when pgrep itself is missing', () async {
      // "I cannot tell" must not be rendered as "kanshi is not running": the
      // assurance line would then claim the layout will not come back on a
      // machine where it will.
      final runner =
          FakeProcessRunner(throwing: {'pgrep -x kanshi'});
      expect(await daemon(runner).isRunning(), isNull);
    });
  });
}
