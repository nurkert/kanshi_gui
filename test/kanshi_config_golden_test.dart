import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/services/config_service.dart';
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
    group('a config the parser cannot fully read survives being saved', () {
      // M2 made this safe by REFUSING to save. M9 makes it safe by not
      // losing anything: the save edits the document in place and only
      // replaces the directives this app owns, so refusing is no longer
      // necessary — and would leave these users with a read-only app for no
      // remaining reason.
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('kanshi_golden_'));
      tearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });

      Future<String> saveOver(String fixture) async {
        final source = _read(fixture);
        final path = '${tmp.path}/config';
        File(path).writeAsStringSync(source);
        final cfg = ConfigService(
          configPath: path,
          backupPrefix: '${tmp.path}/backups/config.bak',
          writeOptions: KanshiWriteOptions.neutral,
        );
        await cfg.saveProfiles(KanshiConfigParser.parse(source));
        return File(path).readAsStringSync();
      }

      test('an include directive is still there afterwards', () async {
        final out = await saveOver('manpage_include_and_block.conf');
        expect(out, contains('include /etc/kanshi/config.d/*'));
      });

      test('a braced output block is still there afterwards', () async {
        final out = await saveOver('manpage_include_and_block.conf');
        expect(out, contains('output "Some Company ASDF 4242" {'));
        expect(out, contains('mode 1600x900'));
      });

      test("a hand-written exec is still there afterwards", () async {
        final out = await saveOver('manpage_exec.conf');
        expect(out,
            contains('exec swaymsg workspace 1, move workspace to eDP-1'));
      });

      test('a global output default is still there afterwards', () async {
        final out = await saveOver('manpage_output_defaults.conf');
        expect(out, contains('output eDP-1 scale 2'));
      });

      test('adaptive_sync, alias and the ellipsis form survive', () async {
        final out = await saveOver('directives_full.conf');
        // adaptive_sync sits ON an output line the app rewrites, so it only
        // survives because unmodelled parameters are carried across verbatim.
        expect(out, contains('adaptive_sync on'));
        expect(out, contains(r'alias $desk-main'));
        expect(out, contains('...output'));
      });

      test('a custom mode is still lost when the app rewrites that output',
          () async {
        // The one gap left, stated rather than hidden. `mode` is a field the
        // app owns and replaces, and its model has no flag for `--custom`, so
        // rewriting the line writes a plain mode. Everything else on that
        // line is preserved. Closing this needs the model to carry the flag,
        // which is a change to MonitorTileData rather than to the document
        // layer.
        final out = await saveOver('directives_full.conf');
        expect(out, isNot(contains('mode --custom')));
      });

      test('a profile the parser cannot read is not deleted', () async {
        // The old writer skipped empty profiles, so a profile it could not
        // read vanished. Absence from the model means "I could not see it",
        // not "the user removed it".
        final out = await saveOver('handwritten_minimal.conf');
        expect(out, contains('profile docked {'));
        expect(out, contains('output eDP-1 position 0,0'));
      });

      test('the file is not emptied', () async {
        for (final f in const [
          'handwritten_minimal.conf',
          'manpage_output_defaults.conf',
        ]) {
          expect((await saveOver(f)).trim(), isNotEmpty, reason: f);
        }
      });
    });

    group('diagnose() reports what the parser could not read', () {
      test('the app\'s own dialect is lossless', () {
        expect(KanshiConfigParser.diagnose(_read('writer_dialect.conf'))
            .isLossless, isTrue);
      });

      test('an omitted `enable` keyword loses every output', () {
        final d = KanshiConfigParser.diagnose(_read('handwritten_minimal.conf'));
        expect(d.isLossless, isFalse);
        expect(d.outputsInFile, 3);
        expect(d.outputsParsed, 0);
        expect(d.lossDescription, contains('3 of 3 output lines'));
      });

      test('global output defaults are counted separately', () {
        final d =
            KanshiConfigParser.diagnose(_read('manpage_output_defaults.conf'));
        expect(d.globalOutputDefaults, 1);
        expect(d.isLossless, isFalse);
      });
    });

    group('what the model still cannot read', () {
      // Stated rather than skipped. Since M9 these are no longer DANGEROUS —
      // the save preserves them, as the group above asserts — but the model
      // still cannot see them, so they do not appear in the GUI. Teaching the
      // model to read them is a change to KanshiConfigParser and
      // MonitorTileData, not to the document layer.
      test('an unnamed profile is invisible to the model', () {
        final profiles =
            KanshiConfigParser.parse(_read('manpage_include_and_block.conf'));
        expect(profiles.map((p) => p.name), ['nomad'],
            reason: 'the unnamed profile is preserved on save but not shown');
      });

      test('a profile keyed by description without `enable` is invisible', () {
        final profiles = KanshiConfigParser.parse(_read('manpage_exec.conf'));
        expect(
          profiles.firstWhere((p) => p.name == 'complex').monitors,
          isEmpty,
        );
      });

      test('the ellipsis form is invisible', () {
        final profiles = KanshiConfigParser.parse(_read('directives_full.conf'));
        expect(
          profiles.firstWhere((p) => p.name == 'ellipsis').monitors,
          isEmpty,
        );
      });

      test('a flipped transform loses its flip', () {
        // rotation is an int, so `flipped-90` and `90` are the same value to
        // the model. Fixing it means a Transform type that can express a
        // flip, which is the domain rewrite in PLAN-2.0.md D2.
        final m = KanshiConfigParser.parse(_read('directives_full.conf'))
            .firstWhere((p) => p.name == 'everything')
            .monitors
            .firstWhere((m) => m.id == 'eDP-1');
        expect(m.rotation, 90);
      });
    });

    group('saving is idempotent', () {
      // A save must be a fixed point: rendering the same model twice has to
      // produce the same bytes. Where it does not, repeated saves walk the
      // config somewhere the user never asked it to go. Three of these
      // fixtures carry a rotated output, which is what made this fail before
      // M1 fixed the transposed-mode fallback.
      for (final fixture in const [
        'manpage_include_and_block.conf',
        'manpage_exec.conf', // DP-1 transform 270
        'directives_full.conf', // eDP-1 flipped-90
        'writer_dialect.conf', // HDMI-A-2 transform 270
      ]) {
        test(fixture, () {
          final once = _roundTrip(fixture);
          final twice = KanshiConfigWriter.render(KanshiConfigParser.parse(once));
          expect(twice, once, reason: 'a second save changed the file again');
        });
      }
    });

    test('a rotated output keeps its physical mode across repeated saves', () {
      // MonitorTileData.width/height carry the ROTATED extent, a MonitorMode
      // is a PHYSICAL panel mode. When the modes list is empty — which it
      // always is for outputs loaded from the config file — the writer's
      // fallback used to hand the rotated extent back as a physical mode, so
      // a `transform 270` output oscillated between 1920x1080 and 1080x1920
      // and every second save asked the panel for a mode it does not have.
      var current = _read('writer_dialect.conf');
      final seen = <String>{};
      for (var i = 0; i < 4; i++) {
        current = KanshiConfigWriter.render(KanshiConfigParser.parse(current));
        seen.add(_modeOf(current, 'HDMI-A-2'));
      }
      expect(seen, hasLength(1),
          reason: 'the mode of the rotated output changed between saves: $seen');
      expect(seen.single, '1920x1080@60Hz');
    });
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
