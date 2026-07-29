import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/state/save_coordinator.dart';

MonitorTileData _mon({String id = 'A', double x = 0}) => MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_save_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConfigService cfg() => ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/backups/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
      );

  List<Profile> profiles([double x = 0]) =>
      [Profile(name: 'P', monitors: [_mon(x: x)])];

  test('a burst of edits collapses into one write', () async {
    // A drag calls schedule() on every frame. Without the debounce that is a
    // config rewrite, a backup and a round-trip verification per frame.
    final c = cfg();
    // Generous debounce relative to the burst: 20 synchronous schedule()
    // calls cannot straddle it unless the machine stalls for a fifth of a
    // second mid-loop. A 40ms window turned out to be tight enough to fail
    // occasionally under the loaded parallel suite while passing in
    // isolation — a flaky test is worse than no test.
    final s = SaveCoordinator(c, debounce: const Duration(milliseconds: 200));
    for (var i = 0; i < 20; i++) {
      s.schedule(profiles(i.toDouble()));
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(s.lastSaveOk, isTrue);
    final onDisk =
        KanshiConfigParser.parse(File('${tmp.path}/config').readAsStringSync());
    expect(onDisk.single.monitors.single.x, 19,
        reason: 'the last edit of the burst is the one persisted');
    // ConfigService backs up the previous file before every write, so a
    // second write would leave exactly one backup behind. None means the
    // burst produced a single write.
    final backups = Directory('${tmp.path}/backups');
    expect(backups.existsSync() ? backups.listSync().length : 0, 0,
        reason: 'a burst must produce one write, not one per frame');
    s.dispose();
  });

  test('an include directive is no longer a reason to refuse', () async {
    // It was, while the save re-rendered the file from the model and would
    // have dropped the line. Since M9 the save edits in place and the line
    // stays, so refusing would only take the app away for nothing.
    File('${tmp.path}/config')
        .writeAsStringSync('include /etc/kanshi/config.d/*\n');
    final s = SaveCoordinator(cfg());
    await s.inspect();

    expect(s.blockedReason, isNull);
    expect(await s.flush(profiles()), isTrue);
    expect(File('${tmp.path}/config').readAsStringSync(),
        contains('include /etc/kanshi/config.d/*'));
    s.dispose();
  });

  test('a config the parser cannot fully read is still saveable', () async {
    // kanshi makes `enable` optional and the parser does not, so this reads
    // as zero monitors. In-place editing means that is no longer dangerous.
    File('${tmp.path}/config').writeAsStringSync(
        'profile docked {\n    output eDP-1 position 0,0\n}\n');
    final s = SaveCoordinator(cfg());
    await s.inspect();

    expect(s.unparsedLoss, isNotNull,
        reason: 'the app still knows what it could not read');
    expect(s.blockedReason, isNull, reason: 'but it no longer refuses');
    expect(await s.flush(profiles()), isTrue);
    expect(File('${tmp.path}/config').readAsStringSync(),
        contains('output eDP-1 position 0,0'));
    s.dispose();
  });

  test('a write failure is routed, not swallowed', () async {
    final c = cfg();
    final s = SaveCoordinator(c);
    await s.flush(profiles());

    Process.runSync('chmod', ['500', tmp.path]);
    addTearDown(() => Process.runSync('chmod', ['700', tmp.path]));

    String? reason;
    s.onBlocked = (r) => reason = r;
    expect(await s.flush(profiles(640)), isFalse);
    expect(s.lastSaveOk, isFalse);
    expect(reason, contains('kept'),
        reason: 'the user must learn their changes are memory-only');
    s.dispose();
  });

  test('cancel drops a pending write without performing it', () async {
    final c = cfg();
    final s = SaveCoordinator(c, debounce: const Duration(milliseconds: 40));
    s.schedule(profiles());
    s.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(File('${tmp.path}/config').existsSync(), isFalse);
    expect(s.lastSaveOk, isNull);
    s.dispose();
  });
}
