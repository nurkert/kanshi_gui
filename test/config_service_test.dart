import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_cfg_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ConfigService make({int maxBackups = 10}) => ConfigService(
        configPath: '${tmp.path}/config',
        backupPrefix: '${tmp.path}/config.bak',
        writeOptions: KanshiWriteOptions.neutral,
        maxBackups: maxBackups,
      );

  Profile profileNamed(String name) => Profile(name: name, monitors: []);

  group('ConfigService.saveProfiles backup rotation', () {
    test('first save creates no backup (no prior live config)', () async {
      final cfg = make();
      await cfg.saveProfiles([profileNamed('first')]);
      final backups = await cfg.listBackups();
      expect(backups, isEmpty,
          reason: 'No prior config existed, so no backup snapshot.');
      expect(File('${tmp.path}/config').existsSync(), isTrue);
    });

    test('subsequent saves write timestamped backups', () async {
      final cfg = make();
      await cfg.saveProfiles([profileNamed('a')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await cfg.saveProfiles([profileNamed('b')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await cfg.saveProfiles([profileNamed('c')]);

      final backups = await cfg.listBackups();
      // Three saves total: the first leaves no backup, the second snapshots
      // the first's content, and the third snapshots the second's content.
      expect(backups, hasLength(2));
      // Newest first; both files have the timestamped suffix.
      expect(
        backups.first.path,
        matches(RegExp(r'/config\.bak\.\d+$')),
      );
    });

    test('rotation keeps only the newest maxBackups entries', () async {
      final cfg = make(maxBackups: 3);
      // 6 saves — first leaves no backup, next 5 leave one each. After
      // rotation only the newest 3 should remain.
      for (var i = 0; i < 6; i++) {
        await cfg.saveProfiles([profileNamed('p$i')]);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final backups = await cfg.listBackups();
      expect(backups, hasLength(3));
    });

    test('atomic write does not leak the .tmp sibling on success', () async {
      final cfg = make();
      await cfg.saveProfiles([profileNamed('x')]);
      expect(File('${tmp.path}/config.tmp').existsSync(), isFalse);
    });

    test('newestBackup returns null when no backup exists', () async {
      final cfg = make();
      expect(await cfg.newestBackup(), isNull);
    });

    test('newestBackup picks the most recent timestamped file', () async {
      final cfg = make();
      await cfg.saveProfiles([profileNamed('a')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await cfg.saveProfiles([profileNamed('b')]);
      final newest = await cfg.newestBackup();
      expect(newest, isNotNull);
      expect(newest!.path, matches(RegExp(r'/config\.bak\.\d+$')));
    });

    test('listBackups ignores non-timestamped sibling files', () async {
      // Drop a stray non-numeric-suffix file in the same directory and
      // assert it is not enumerated as a backup.
      File('${tmp.path}/config.bak.notes').writeAsStringSync('decoy');
      final cfg = make();
      await cfg.saveProfiles([profileNamed('a')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await cfg.saveProfiles([profileNamed('b')]);
      final backups = await cfg.listBackups();
      expect(backups, hasLength(1));
      expect(backups.first.path, isNot(contains('notes')));
    });
  });
}
