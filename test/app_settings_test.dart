import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/app_settings.dart';

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
}
