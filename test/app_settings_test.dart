import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_settings_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('defaults firstRunDone to false when file does not exist', () async {
    final s = await AppSettings.load(path: '${tmp.path}/missing.json');
    expect(s.firstRunDone, isFalse);
  });

  test('round-trips firstRunDone through save/load', () async {
    final p = '${tmp.path}/settings.json';
    final s = await AppSettings.load(path: p);
    s.firstRunDone = true;
    await s.save();
    final loaded = await AppSettings.load(path: p);
    expect(loaded.firstRunDone, isTrue);
  });

  test('falls back to defaults when JSON is malformed', () async {
    final p = '${tmp.path}/broken.json';
    await File(p).writeAsString('not-json');
    final s = await AppSettings.load(path: p);
    expect(s.firstRunDone, isFalse);
  });

  group('workspaceManagement', () {
    test('defaults to off for a fresh install (no settings file)', () async {
      final s = await AppSettings.load(path: '${tmp.path}/missing.json');
      expect(s.workspaceManagement, WorkspaceManagementMode.off);
    });

    test('migrates an existing settings file without the key to interleaved',
        () async {
      // Pre-feature settings.json: written by a version where workspace
      // management was unconditionally on. Preserve that behaviour on
      // upgrade rather than silently disabling it.
      final p = '${tmp.path}/legacy.json';
      await File(p).writeAsString('{"firstRunDone": true}');
      final s = await AppSettings.load(path: p);
      expect(s.workspaceManagement, WorkspaceManagementMode.interleaved);
    });

    test('round-trips each mode through save/load', () async {
      for (final mode in WorkspaceManagementMode.values) {
        final p = '${tmp.path}/ws_${mode.name}.json';
        final s = await AppSettings.load(path: p);
        s.workspaceManagement = mode;
        await s.save();
        final loaded = await AppSettings.load(path: p);
        expect(loaded.workspaceManagement, mode);
      }
    });

    test('unrecognised mode string falls back to off', () async {
      final p = '${tmp.path}/weird.json';
      await File(p).writeAsString('{"workspaceManagement": "bogus"}');
      final s = await AppSettings.load(path: p);
      expect(s.workspaceManagement, WorkspaceManagementMode.off);
    });

    test('mode → distribution mapping', () {
      expect(WorkspaceManagementMode.off.distribution, isNull);
      expect(WorkspaceManagementMode.interleaved.distribution,
          WorkspaceDistribution.interleaved);
      expect(WorkspaceManagementMode.grouped.distribution,
          WorkspaceDistribution.grouped);
    });
  });

  group('the surviving preferences', () {
    // Ten preferences were removed in M8: snap distance, scale snapping, the
    // two countdown lengths, both toast toggles, the apply-revert flag, the
    // identify duration, the backup count and the accent override. Each was a
    // question the app should answer itself, and each is now derived, fixed,
    // or read from sway. What is left is what the app genuinely cannot decide
    // for the user.
    test('a fresh install starts on the defaults', () async {
      final s = await AppSettings.load(path: '${tmp.path}/fresh.json');
      expect(s.themeChoice, AppThemeChoice.dark);
      expect(s.mirrorScaling, MirrorScaling.fit);
      expect(s.kanshiConfigPath, isNull);
      expect(s.autoReapplyOnDrift, isFalse);
      expect(s.liveApply, isTrue);
    });

    test('they round-trip through save and load', () async {
      final p = '${tmp.path}/full.json';
      final s = await AppSettings.load(path: p);
      s.themeChoice = AppThemeChoice.system;
      s.mirrorScaling = MirrorScaling.cover;
      s.kanshiConfigPath = '/tmp/custom/kanshi';
      s.autoReapplyOnDrift = true;
      s.liveApply = false;
      await s.save();

      final loaded = await AppSettings.load(path: p);
      expect(loaded.themeChoice, AppThemeChoice.system);
      expect(loaded.mirrorScaling, MirrorScaling.cover);
      expect(loaded.kanshiConfigPath, '/tmp/custom/kanshi');
      expect(loaded.autoReapplyOnDrift, isTrue);
      expect(loaded.liveApply, isFalse);
    });

    test('keys from the old schema are ignored, not fatal', () async {
      // Every existing install has them. Reading such a file must not throw
      // and must not reset the preferences that DID survive.
      final p = '${tmp.path}/legacy.json';
      File(p).writeAsStringSync(
        '{"themeChoice":"light","snapDistance":120.5,"maxBackups":42,'
        '"accentArgb":4282549748,"hotplugToasts":false}',
      );
      final loaded = await AppSettings.load(path: p);
      expect(loaded.themeChoice, AppThemeChoice.light);
    });

    test('the next save drops the keys that no longer exist', () async {
      final p = '${tmp.path}/legacy2.json';
      File(p).writeAsStringSync('{"themeChoice":"light","maxBackups":42}');
      final loaded = await AppSettings.load(path: p);
      await loaded.save();
      expect(File(p).readAsStringSync(), isNot(contains('maxBackups')));
    });
  });
}
