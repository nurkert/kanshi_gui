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

  group('extended preferences', () {
    test('all new fields default sensibly on a fresh install', () async {
      final s = await AppSettings.load(path: '${tmp.path}/fresh.json');
      expect(s.safetyNetSeconds, 15);
      expect(s.customModeRevertSeconds, 10);
      expect(s.hotplugToasts, isTrue);
      expect(s.profileSuggestionToasts, isTrue);
      expect(s.snapDistance, 60.0);
      expect(s.scaleSnapping, isTrue);
      expect(s.themeChoice, AppThemeChoice.dark);
      expect(s.accentArgb, isNull);
      expect(s.identifyBannerSeconds, 3);
      expect(s.mirrorScaling, MirrorScaling.fit);
      expect(s.maxBackups, 10);
      expect(s.kanshiConfigPath, isNull);
      expect(s.autoReapplyOnDrift, isFalse);
    });

    test('round-trips all new fields through save/load', () async {
      final p = '${tmp.path}/full.json';
      final s = await AppSettings.load(path: p);
      s.safetyNetSeconds = 0;
      s.customModeRevertSeconds = 25;
      s.hotplugToasts = false;
      s.profileSuggestionToasts = false;
      s.snapDistance = 120.5;
      s.scaleSnapping = false;
      s.themeChoice = AppThemeChoice.system;
      s.accentArgb = 0xFF42A5F5;
      s.identifyBannerSeconds = 7;
      s.mirrorScaling = MirrorScaling.cover;
      s.maxBackups = 42;
      s.kanshiConfigPath = '/tmp/custom/kanshi';
      s.autoReapplyOnDrift = true;
      await s.save();

      final loaded = await AppSettings.load(path: p);
      expect(loaded.safetyNetSeconds, 0);
      expect(loaded.customModeRevertSeconds, 25);
      expect(loaded.hotplugToasts, isFalse);
      expect(loaded.profileSuggestionToasts, isFalse);
      expect(loaded.snapDistance, 120.5);
      expect(loaded.scaleSnapping, isFalse);
      expect(loaded.themeChoice, AppThemeChoice.system);
      expect(loaded.accentArgb, 0xFF42A5F5);
      expect(loaded.identifyBannerSeconds, 7);
      expect(loaded.mirrorScaling, MirrorScaling.cover);
      expect(loaded.maxBackups, 42);
      expect(loaded.kanshiConfigPath, '/tmp/custom/kanshi');
      expect(loaded.autoReapplyOnDrift, isTrue);
    });

    test('resetToDefaults restores everything but keeps firstRunDone',
        () async {
      final p = '${tmp.path}/reset.json';
      final s = await AppSettings.load(path: p);
      s.firstRunDone = true;
      s.themeChoice = AppThemeChoice.light;
      s.snapDistance = 5;
      s.workspaceManagement = WorkspaceManagementMode.grouped;
      s.resetToDefaults();
      expect(s.firstRunDone, isTrue, reason: 'must not re-trigger the wizard');
      expect(s.themeChoice, AppThemeChoice.dark);
      expect(s.snapDistance, 60.0);
      expect(s.workspaceManagement, WorkspaceManagementMode.off);
    });

    test('empty kanshiConfigPath string loads as null (default path)',
        () async {
      final p = '${tmp.path}/emptypath.json';
      await File(p).writeAsString('{"kanshiConfigPath": ""}');
      final s = await AppSettings.load(path: p);
      expect(s.kanshiConfigPath, isNull);
    });
  });
}
