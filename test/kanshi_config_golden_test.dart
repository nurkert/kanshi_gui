import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

/// Golden corpus: real kanshi config files in, parse/render round trip out.
///
/// Every fixture under `test/fixtures/kanshi/` is a config kanshi itself
/// accepts — most of them are lifted verbatim from the `kanshi(5)` manual.
/// Until v2.0 the app had no test that fed it a config it had not written
/// itself, which is exactly why the round trip was free to lose data.
///
/// Tests that are `skip`ped here describe behaviour the app does not have
/// yet. The skip reason names the milestone that removes it, so deleting a
/// skip is the acceptance criterion for that milestone — not a chore.
void main() {
  group('golden corpus', () {
    group('saving never empties a config kanshi accepts', () {
      test('hand-written config without the optional `enable` keyword', () {
        // kanshi's DSL makes `enable` optional. The parser requires it
        // (kanshi_config_parser.dart:382), so every profile reads as zero
        // monitors, and render() skips empty profiles
        // (kanshi_config_writer.dart:87) — the file renders to "".
        expectSurvivesSave('handwritten_minimal.conf');
      }, skip: 'M2 — round-trip refusal gate; M9 — scfg AST');

      test('global output defaults (kanshi(5) example)', () {
        expectSurvivesSave('manpage_output_defaults.conf');
      }, skip: 'M2 — round-trip refusal gate; M9 — scfg AST');
    });

    group('no profile disappears', () {
      test('unnamed profile with a braced output block survives', () {
        final profiles =
            KanshiConfigParser.parse(_read('manpage_include_and_block.conf'));
        // The file holds two profiles: an unnamed one and `nomad`.
        expect(profiles.length, 2);
      }, skip: 'M9 — scfg AST (unnamed profiles, braced output blocks)');

      test('profile keyed by output description survives', () {
        final profiles = KanshiConfigParser.parse(_read('manpage_exec.conf'));
        expect(profiles.map((p) => p.name), containsAll(['multihead', 'complex']));
        expect(
          profiles.firstWhere((p) => p.name == 'complex').monitors,
          isNotEmpty,
        );
      }, skip: 'M9 — scfg AST (description criteria without `enable`)');

      test('ellipsis form `...output` survives', () {
        final profiles = KanshiConfigParser.parse(_read('directives_full.conf'));
        expect(
          profiles.firstWhere((p) => p.name == 'ellipsis').monitors,
          isNotEmpty,
        );
      }, skip: 'M9 — scfg AST');
    });

    group('directives the model does not own are passed through untouched', () {
      test('include directive', () {
        expect(_roundTrip('manpage_include_and_block.conf'),
            contains('include /etc/kanshi/config.d/*'));
      }, skip: 'M9 — scfg AST (opaque node passthrough)');

      test('exec lines', () {
        expect(_roundTrip('manpage_exec.conf'),
            contains('exec swaymsg workspace 1, move workspace to eDP-1'));
      }, skip: 'M9 — scfg AST (opaque node passthrough)');

      test('adaptive_sync', () {
        expect(_roundTrip('directives_full.conf'), contains('adaptive_sync on'));
      }, skip: 'M9 — scfg AST');

      test('output alias', () {
        expect(_roundTrip('directives_full.conf'),
            contains(r'alias $desk-main'));
      }, skip: 'M9 — scfg AST');

      test('flipped transforms keep their flip', () {
        expect(_roundTrip('directives_full.conf'), contains('flipped-90'));
      }, skip: 'M9 — scfg AST (Transform is an int, so flips cannot be held)');
    });

    group('saving is idempotent', () {
      // A save must be a fixed point: rendering the same model twice has to
      // produce the same bytes. Where it does not, repeated saves walk the
      // config somewhere the user never asked it to go.
      //
      // The three fixtures that carry a rotated output fail for one shared
      // reason — the transposed-mode oscillation below — so they name the
      // milestone that fixes it rather than the symptom.
      const rotationOscillation = 'M1 (A1.5) — the transposed-mode oscillation';
      const fixtures = <String, String?>{
        'manpage_include_and_block.conf': null,
        'manpage_exec.conf': rotationOscillation, // DP-1 transform 270
        'directives_full.conf': rotationOscillation, // eDP-1 flipped-90
        'writer_dialect.conf': rotationOscillation, // HDMI-A-2 transform 270
      };
      fixtures.forEach((fixture, skipReason) {
        test(fixture, () {
          final once = _roundTrip(fixture);
          final twice = KanshiConfigWriter.render(KanshiConfigParser.parse(once));
          expect(twice, once, reason: 'a second save changed the file again');
        }, skip: skipReason);
      });
    });

    test('a rotated output keeps its physical mode across repeated saves', () {
      // The parser stores width/height ALREADY ROTATED (parser:420) while the
      // writer transposes again on the way out (writer:312), so a `transform
      // 270` output oscillates between 1920x1080 and 1080x1920 on every save.
      // Every other save therefore writes a mode the panel cannot do.
      var current = _read('writer_dialect.conf');
      final seen = <String>{};
      for (var i = 0; i < 4; i++) {
        current = KanshiConfigWriter.render(KanshiConfigParser.parse(current));
        seen.add(_modeOf(current, 'HDMI-A-2'));
      }
      expect(seen, hasLength(1),
          reason: 'the mode of the rotated output changed between saves: $seen');
      expect(seen.single, '1920x1080@60Hz');
    }, skip: 'M1 (A1.5) — the transposed-mode oscillation');
  });
}

const _fixtureDir = 'test/fixtures/kanshi';

String _read(String name) => File('$_fixtureDir/$name').readAsStringSync();

String _roundTrip(String name) =>
    KanshiConfigWriter.render(KanshiConfigParser.parse(_read(name)));

/// The `WxH@RHz` token of [outputId]'s line in a rendered config.
String _modeOf(String rendered, String outputId) {
  final line = rendered
      .split('\n')
      .firstWhere((l) => l.contains("'$outputId'"), orElse: () => '');
  final match = RegExp(r'mode (\S+)').firstMatch(line);
  return match?.group(1) ?? '<no mode>';
}

/// Asserts that saving [name] does not throw away the profiles it contains.
void expectSurvivesSave(String name) {
  final source = _read(name);
  final rendered = _roundTrip(name);
  expect(rendered.trim(), isNotEmpty,
      reason: 'saving rendered the whole config to nothing');
  final sourceProfiles = RegExp(r'^\s*profile\b', multiLine: true)
      .allMatches(source)
      .length;
  final renderedProfiles = RegExp(r'^\s*profile\b', multiLine: true)
      .allMatches(rendered)
      .length;
  expect(renderedProfiles, sourceProfiles,
      reason: 'profiles went missing: $sourceProfiles in, $renderedProfiles out');
}
