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

  group('include-directive detection', () {
    // kanshi's DSL supports `include <pattern>` to split profiles
    // across files. The GUI parses only the main file, so a save
    // would render only the profiles it knows about and silently
    // overwrite the include line — orphaning every profile in the
    // included files. ConfigService refuses the save instead.
    test('returns false for a config with no include line', () async {
      final cfg = make();
      await cfg.saveProfiles([profileNamed('a')]);
      // Cached false stays false even with re-read.
      expect(await cfg.hasIncludeDirectives(), isFalse);
    });

    test('returns true for a config with an include line', () async {
      final cfg = make();
      await File('${tmp.path}/config').writeAsString(
        'include /etc/kanshi.d/work\nprofile foo {\n}\n',
      );
      expect(await cfg.hasIncludeDirectives(), isTrue);
    });

    test('ignores include lines that are commented out', () async {
      final cfg = make();
      // `#`-prefixed entire-line comment AND a trailing-comment form
      // — neither should trigger detection.
      await File('${tmp.path}/config').writeAsString(
        '# include /etc/old\n'
        'profile foo {\n'
        '} # include /etc/notes\n',
      );
      expect(await cfg.hasIncludeDirectives(), isFalse);
    });

    test(
        'saveProfiles throws ConfigHasIncludesException for an '
        'include-using config and leaves the file unchanged',
        () async {
      const originalContent =
          'include /etc/kanshi.d/work\nprofile foo {\n}\n';
      await File('${tmp.path}/config').writeAsString(originalContent);
      final cfg = make();
      await expectLater(
        cfg.saveProfiles([profileNamed('overwriting')]),
        throwsA(isA<ConfigHasIncludesException>()),
      );
      final after = await File('${tmp.path}/config').readAsString();
      expect(after, equals(originalContent),
          reason: 'A blocked save must leave the existing config '
              'untouched — orphaning the user\'s included profiles '
              'is exactly the failure mode we are preventing.');
    });

    test('hasIncludeDirectives caches the answer after first call',
        () async {
      // The hot save-path calls this on every flush; re-reading the
      // file each time would be wasteful and flaky under filesystem
      // contention. The controller treats include-status as stable
      // for the lifetime of the session — a user who mid-session
      // adds includes needs to relaunch.
      await File('${tmp.path}/config').writeAsString('profile foo {\n}\n');
      final cfg = make();
      expect(await cfg.hasIncludeDirectives(), isFalse);
      await File('${tmp.path}/config').writeAsString(
        'include /tmp/added-later\nprofile foo {\n}\n',
      );
      expect(await cfg.hasIncludeDirectives(), isFalse,
          reason: 'Cached "no includes" must survive a runtime edit '
              'of the file.');
    });
  });
}
