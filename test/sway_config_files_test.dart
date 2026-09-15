import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/sway_config_files.dart';

import 'fakes/fake_process_runner.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_swaycfg_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File write(String rel, String content) {
    final f = File('${tmp.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  group('which file sway reads', () {
    test("sway's own search order", () {
      expect(
        SwayConfigFiles.searchPaths({'HOME': '/home/u'}),
        [
          '/home/u/.sway/config',
          '/home/u/.config/sway/config',
          '/home/u/.i3/config',
          '/home/u/.config/i3/config',
          '/etc/sway/config',
          '/etc/i3/config',
        ],
      );
      expect(
        SwayConfigFiles.searchPaths(
            {'HOME': '/home/u', 'XDG_CONFIG_HOME': '/xdg'})[1],
        '/xdg/sway/config',
      );
    });

    test('the file the running sway names wins over the search', () async {
      write('.config/sway/config', '');
      final runner = FakeProcessRunner(responses: {
        'swaymsg -t get_version': ProcessResult(0, 0,
            '{"human_readable":"1.12","loaded_config_file_name":"/opt/sway.conf"}',
            ''),
      });
      expect(
        await SwayConfigFiles.locate(
            runner: runner, environment: {'HOME': tmp.path}),
        '/opt/sway.conf',
      );
    });

    test('without a sway to ask, the first file that exists', () async {
      final f = write('.config/sway/config', '');
      final runner = FakeProcessRunner(
          throwing: {'swaymsg -t get_version'});
      expect(
        await SwayConfigFiles.locate(
            runner: runner, environment: {'HOME': tmp.path}),
        f.path,
      );
    });
  });

  group('reading it', () {
    test('follows includes relative to the including file, in glob order',
        () async {
      final main = write('sway/config', 'a\ninclude config.d/*\nz\n');
      write('sway/config.d/20-second', 'second');
      write('sway/config.d/10-first', 'first');
      final lines = await SwayConfigFiles.readLines(main.path);
      expect(lines.map((l) => l.text), ['a', 'first', 'second', 'z']);
      expect(lines[1].path, endsWith('config.d/10-first'));
      expect(lines[1].number, 1);
      expect(lines.last.number, 3);
    });

    test('joins a line continued with a backslash, numbered from its start',
        () async {
      final main = write('config', 'x\nexec foo && \\\n  bar\ny\n');
      final lines = await SwayConfigFiles.readLines(main.path);
      expect(lines.map((l) => l.text), ['x', 'exec foo &&   bar', 'y']);
      expect(lines[1].number, 2);
      expect(lines[2].number, 4);
    });

    test('a file that includes itself is read once', () async {
      final main = write('config', 'one\ninclude config\n');
      final lines = await SwayConfigFiles.readLines(main.path);
      expect(lines.map((l) => l.text), ['one']);
    });

    test('a missing include is skipped, a missing config throws', () async {
      final main = write('config', 'one\ninclude nowhere/*\ninclude gone\n');
      expect((await SwayConfigFiles.readLines(main.path)).map((l) => l.text),
          ['one']);
      expect(SwayConfigFiles.readLines('${tmp.path}/absent'),
          throwsA(isA<FileSystemException>()));
    });
  });
}
