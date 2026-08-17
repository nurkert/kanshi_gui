import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/workspace_apply_lock.dart';

/// Two PROCESSES can send workspace commands to the same compositor: the app,
/// when the user changes something, and the helper, when a screen appears.
/// Each serialises its own work and neither knows about the other, so a
/// hotplug while the app is open had both walking the workspaces at once.
///
/// Across processes is the only thing that matters here, and it is also the
/// only thing that works: Dart's file locks are POSIX `fcntl` record locks,
/// which are owned by the process. A process asking twice always succeeds —
/// so a test that opens the lock twice in one isolate proves nothing, and an
/// earlier draft of this file "passed" while measuring exactly that.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_lock_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  WorkspaceApplyLock lock() =>
      WorkspaceApplyLock('apply.lock', directory: tmp.path);

  /// Starts a second process holding the same lock, and waits until it says
  /// it has it. Uses the same API the real class uses, so what is measured is
  /// the mechanism and not a mock of it.
  Future<Process> holdInAnotherProcess() async {
    final script = File('${tmp.path}/holder.dart')..writeAsStringSync('''
import 'dart:io';
void main() {
  final f = File('${tmp.path}/apply.lock').openSync(mode: FileMode.write);
  f.lockSync(FileLock.exclusive);
  File('${tmp.path}/held').writeAsStringSync('yes');
  sleep(const Duration(seconds: 30));
}
''');
    final p = await Process.start('dart', ['run', script.path]);
    final held = File('${tmp.path}/held');
    for (var i = 0; i < 200 && !held.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return p;
  }

  test('a second process cannot take a lock someone else holds', () async {
    final other = await holdInAnotherProcess();
    addTearDown(() => other.kill());
    expect(File('${tmp.path}/held').existsSync(), isTrue,
        reason: 'the other process never got the lock, so this proves nothing');

    expect(lock().tryHold(), isFalse,
        reason: 'both would walk the workspaces at the same time');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('and takes it once the other lets go', () async {
    final other = await holdInAnotherProcess();
    expect(lock().tryHold(), isFalse);

    other.kill();
    await other.exitCode;

    final mine = lock();
    addTearDown(mine.release);
    expect(mine.tryHold(), isTrue,
        reason: 'the kernel releases it when the holder dies');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('guard steps aside when another process is mid-apply', () async {
    final other = await holdInAnotherProcess();
    addTearDown(() => other.kill());

    var ran = false;
    expect(await lock().guard(() async => ran = true), isFalse);
    expect(ran, isFalse,
        reason: 'whoever holds it is on the way to the same end state');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('guard runs the work and always gives the lock back', () async {
    var ran = 0;
    expect(await lock().guard(() async => ran++), isTrue);
    expect(ran, 1);
    await expectLater(
      lock().guard(() async => throw StateError('boom')),
      throwsStateError,
    );
    // Proven from another process, since this one can always relock itself.
    final probe = await Process.run('dart', [
      'run',
      (File('${tmp.path}/probe.dart')..writeAsStringSync('''
import 'dart:io';
void main() {
  final f = File('${tmp.path}/apply.lock').openSync(mode: FileMode.write);
  try {
    f.lockSync(FileLock.exclusive);
    stdout.write('free');
  } on FileSystemException {
    stdout.write('held');
  }
}
'''))
          .path,
    ]);
    expect(probe.stdout, 'free', reason: 'a thrown step must not wedge it');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a directory it cannot use does not stop the work', () async {
    // Locking is an optimisation, not a correctness requirement: a read-only
    // filesystem or a kernel without record locks must not mean the
    // workspaces stop being placed.
    var ran = false;
    final l = WorkspaceApplyLock('x.lock', directory: '/proc/nonexistent/nope');
    expect(await l.guard(() async => ran = true), isTrue);
    expect(ran, isTrue);
  });
}
