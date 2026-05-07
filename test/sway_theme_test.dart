// Synthetic-config tests for SwayThemeReader. Each test writes a
// throw-away sway config under tmp/, points the reader at it, and
// asserts the extracted accent colour matches what sway would draw
// around a focused window. No real sway / X / Wayland needed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/sway_theme.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kanshi_gui_swaytheme_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<File> writeConfig(String path, String content) async {
    final f = File('${tmp.path}/$path');
    await f.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  test('resolves a sway \$variable used in client.focused', () async {
    // Mirrors the user's real setup: an accent variable defined with
    // `set` and referenced as the first colour in client.focused. The
    // first colour is the active border — that's the accent we want.
    final cfg = await writeConfig('config', '''
set \$c_purple #b162d5
set \$c_bg     #1e1e1e
client.focused \$c_purple \$c_bg #ffffff \$c_purple #8e4bb8
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent, isNotNull);
    expect(accent!.toARGB32(), equals(0xFFB162D5));
  });

  test('reads a bare hex colour without any variable indirection',
      () async {
    final cfg = await writeConfig('config', '''
client.focused #b162d5 #1e1e1e #ffffff #b162d5 #8e4bb8
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent!.toARGB32(), equals(0xFFB162D5));
  });

  test('handles 8-digit hex (with alpha)', () async {
    // Sway accepts `#rrggbbaa`. Make sure alpha lands in the right
    // byte instead of being dropped or shifted into the colour.
    final cfg = await writeConfig('config', '''
client.focused #b162d580 #1e1e1e #ffffff #b162d580 #8e4bb8
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent!.toARGB32(), equals(0x80B162D5));
  });

  test('the LAST client.focused wins (sway redefine semantics)',
      () async {
    // Users sometimes define the directive twice — once in a base
    // file, once in an override. Sway uses the most recent one.
    final cfg = await writeConfig('config', '''
client.focused #ff0000 #1e1e1e #ffffff #ff0000 #8e4bb8
client.focused #00ff00 #1e1e1e #ffffff #00ff00 #8e4bb8
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent!.toARGB32(), equals(0xFF00FF00));
  });

  test('follows an `include` directive with an absolute path',
      () async {
    final included = await writeConfig(
      'theme.conf',
      'set \$accent #abcdef\n',
    );
    final cfg = await writeConfig('config', '''
include ${included.path}
client.focused \$accent #1e1e1e #ffffff \$accent #8e4bb8
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent!.toARGB32(), equals(0xFFABCDEF));
  });

  test('follows an `include` glob (config.d/*) and merges variables',
      () async {
    await writeConfig(
      'config.d/00-colors',
      'set \$accent #112233\n',
    );
    final cfg = await writeConfig('config', '''
include ${tmp.path}/config.d/*
client.focused \$accent #1e1e1e #ffffff \$accent #112233
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent!.toARGB32(), equals(0xFF112233));
  });

  test('strips inline `# …` comments but keeps `#hex` colour tokens',
      () async {
    // The user's config typically has `client.focused …  # accent`
    // explanations. The leading `#` of a colour is NOT preceded by a
    // space-separator, so the comment stripper must distinguish
    // " #comment" (space + hash + non-hex) from " #b162d5" (space +
    // hash + 6 hex digits).
    final cfg = await writeConfig('config', '''
client.focused #b162d5 #1e1e1e #ffffff #b162d5 #8e4bb8 # accent border
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent!.toARGB32(), equals(0xFFB162D5));
  });

  test('returns null when client.focused is absent', () async {
    final cfg = await writeConfig('config', '''
set \$a #b162d5
output * scale 1
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent, isNull);
  });

  test('returns null when the variable cannot be resolved', () async {
    // A profile that references a variable defined in a file we
    // failed to include should fall back to null rather than crash.
    final cfg = await writeConfig('config', '''
client.focused \$undefined_var #1e1e1e #ffffff \$undefined_var #8e4bb8
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent, isNull);
  });

  test('returns null when the colour is malformed', () async {
    final cfg = await writeConfig('config', '''
client.focused notacolor #1e1e1e #ffffff notacolor #8e4bb8
''');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent, isNull);
  });

  test('returns null when the config file does not exist', () async {
    final accent = await SwayThemeReader.readAccentColor(
      configPath: '${tmp.path}/no-such-file',
    );
    expect(accent, isNull);
  });

  test('survives a self-referential include without recursing forever',
      () async {
    // Adversarial: include a file that includes the file. The reader
    // must detect the cycle and stop instead of running until a stack
    // overflow.
    final cfg = await writeConfig('config', '''
include ${tmp.path}/loop
client.focused #b162d5 #1e1e1e #ffffff #b162d5 #8e4bb8
''');
    await writeConfig('loop', 'include ${cfg.path}\n');
    final accent = await SwayThemeReader.readAccentColor(
      configPath: cfg.path,
    );
    expect(accent!.toARGB32(), equals(0xFFB162D5));
  });
}
