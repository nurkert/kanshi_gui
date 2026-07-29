import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/kanshi/kanshi_document.dart';

/// Editing a config in place rather than re-rendering it. The property under
/// test throughout: what the app did not touch comes out exactly as it went
/// in, including the directives it cannot even represent.
void main() {
  String fixture(String name) =>
      File('test/fixtures/kanshi/$name').readAsStringSync();

  test('an untouched document is byte-identical', () {
    for (final name in const [
      'manpage_include_and_block.conf',
      'manpage_exec.conf',
      'directives_full.conf',
      'writer_dialect.conf',
    ]) {
      final src = fixture(name);
      expect(KanshiDocument.parse(src).render(), src, reason: name);
    }
  });

  test('rewriting outputs keeps a hand-written exec line', () {
    // The exact loss that made the old writer dangerous: a user's own exec
    // survived only if the app happened to model it.
    final doc = KanshiDocument.parse(fixture('manpage_exec.conf'));
    final ok = doc.replaceOutputs(
      'multihead',
      outputLines: ["    output 'DP-9' enable"],
      annotationLines: const [],
    );
    expect(ok, isTrue);
    final out = doc.render();
    expect(out, contains('exec swaymsg workspace 1, move workspace to eDP-1'));
    expect(out, contains("output 'DP-9' enable"));
    expect(out, isNot(contains('output eDP-1 enable')));
    // The other profile is untouched, description criteria and all.
    expect(out, contains('output "Some Other Company GTBZ 2525" mode 1920x1200'));
  });

  test('the include directive and global defaults survive an edit', () {
    final doc = KanshiDocument.parse(fixture('manpage_include_and_block.conf'));
    doc.replaceOutputs('nomad',
        outputLines: ['    output LVDS-1 enable scale 1'],
        annotationLines: const []);
    final out = doc.render();
    expect(out, contains('include /etc/kanshi/config.d/*'));
    // And the unnamed profile with its braced output block is still there.
    expect(out, contains('output "Some Company ASDF 4242" {'));
    expect(out, contains('mode 1600x900'));
  });

  test('a braced output block is kept, not silently dropped', () {
    // The app cannot express one, so replacing the flat output lines must
    // leave it alone rather than treating it as an output it owns.
    final doc = KanshiDocument.parse(fixture('manpage_include_and_block.conf'));
    doc.replaceOutputs('',
        outputLines: ['    output LVDS-1 disable'],
        annotationLines: const []);
    expect(doc.render(), contains('output "Some Company ASDF 4242" {'));
  });

  test('our own annotations are replaced, the user\'s comments are not', () {
    const src = 'profile x {\n'
        '    # a note from the user\n'
        "    output 'DP-1' enable\n"
        "    # kanshi_gui:edid 'DP-1'='Old Label'\n"
        '}\n';
    final doc = KanshiDocument.parse(src);
    doc.replaceOutputs('x',
        outputLines: ["    output 'DP-1' enable scale 2"],
        annotationLines: ["    # kanshi_gui:edid 'DP-1'='New Label'"]);
    final out = doc.render();
    expect(out, contains('# a note from the user'));
    expect(out, contains('New Label'));
    expect(out, isNot(contains('Old Label')),
        reason: 'annotations are replaced, not accumulated');
  });

  test('annotations do not accumulate over repeated saves', () {
    var src = 'profile x {\n    output \'DP-1\' enable\n}\n';
    for (var i = 0; i < 3; i++) {
      final doc = KanshiDocument.parse(src);
      doc.replaceOutputs('x',
          outputLines: ["    output 'DP-1' enable"],
          annotationLines: ["    # kanshi_gui:port 'X'='DP-1'"]);
      src = doc.render();
    }
    expect('# kanshi_gui:port'.allMatches(src).length, 1);
  });

  group('profile bookkeeping', () {
    test('lists names, including the unnamed one', () {
      final doc = KanshiDocument.parse(fixture('manpage_include_and_block.conf'));
      expect(doc.profileNames, ['', 'nomad']);
    });

    test('append and remove', () {
      final doc = KanshiDocument.parse('profile a {\n}\n');
      doc.appendProfile(["profile b {", "    output 'DP-1' enable", '}']);
      expect(doc.profileNames, ['a', 'b']);
      expect(doc.removeProfile('a'), isTrue);
      expect(doc.profileNames, ['b']);
      expect(doc.removeProfile('nope'), isFalse);
    });

    test('editing a profile that is not there reports failure', () {
      final doc = KanshiDocument.parse('profile a {\n}\n');
      expect(
        doc.replaceOutputs('missing',
            outputLines: const [], annotationLines: const []),
        isFalse,
      );
    });
  });

  group('hasForeignContent', () {
    test('is false for a file the app could have written itself', () {
      expect(
        KanshiDocument.parse(fixture('writer_dialect.conf')).hasForeignContent,
        isFalse,
      );
    });

    test('is true when anything lives outside a named profile', () {
      for (final name in const [
        'manpage_include_and_block.conf',
        'manpage_output_defaults.conf',
        'directives_full.conf',
      ]) {
        expect(KanshiDocument.parse(fixture(name)).hasForeignContent, isTrue,
            reason: name);
      }
    });
  });
}
