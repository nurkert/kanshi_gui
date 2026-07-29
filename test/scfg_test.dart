import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/kanshi/scfg.dart';

/// The property that matters: a document the app has not edited must come out
/// exactly as it went in. Everything the previous line-based parser lost —
/// includes, aliases, hand-written execs, braced blocks, adaptive_sync,
/// comments — is lost because it was never represented. Here it is.
void main() {
  String roundTrip(String src) => ScfgDocument.parse(src).render();

  group('byte-exact round trip', () {
    for (final name in const [
      'manpage_include_and_block.conf',
      'manpage_output_defaults.conf',
      'manpage_exec.conf',
      'handwritten_minimal.conf',
      'directives_full.conf',
      'writer_dialect.conf',
    ]) {
      test(name, () {
        final src = File('test/fixtures/kanshi/$name').readAsStringSync();
        expect(roundTrip(src), src);
      });
    }
  });

  group('structure', () {
    test('reads an unnamed profile with a braced output block', () {
      final doc = ScfgDocument.parse(
          File('test/fixtures/kanshi/manpage_include_and_block.conf')
              .readAsStringSync());
      final profiles = doc.nodes.where((n) => n.name == 'profile').toList();
      expect(profiles, hasLength(2),
          reason: 'the unnamed profile counts too');
      final unnamed = profiles.first;
      expect(unnamed.params, isEmpty);
      final block = unnamed.children.firstWhere(
          (n) => n.name == 'output' && n.hasBlock);
      expect(block.params.single, 'Some Company ASDF 4242');
      expect(block.children.map((n) => n.name), ['mode', 'position']);
    });

    test('keeps the include directive as a node', () {
      final doc = ScfgDocument.parse(
          File('test/fixtures/kanshi/manpage_include_and_block.conf')
              .readAsStringSync());
      expect(doc.nodes.first.name, 'include');
      expect(doc.nodes.first.params.single, '/etc/kanshi/config.d/*');
    });

    test('reads a global output default, which has no profile around it', () {
      final doc = ScfgDocument.parse(
          File('test/fixtures/kanshi/manpage_output_defaults.conf')
              .readAsStringSync());
      final global = doc.nodes.firstWhere((n) => n.name == 'output');
      expect(global.params, ['eDP-1', 'scale', '2']);
    });

    test('reads the ellipsis form and the alias', () {
      final doc = ScfgDocument.parse(
          File('test/fixtures/kanshi/directives_full.conf')
              .readAsStringSync());
      final alias = doc.nodes.firstWhere((n) => n.name == 'output');
      expect(alias.params, contains(r'$desk-main'));
      final ellipsis = doc.nodes
          .firstWhere((n) => n.params.contains('ellipsis'))
          .children
          .first;
      expect(ellipsis.name, '...output');
    });
  });

  group('quoting', () {
    test('handles double, single and bare parameters', () {
      final (name, params) =
          ScfgDocument.tokenise('''output "A B" 'C D' bare''');
      expect(name, 'output');
      expect(params, ['A B', 'C D', 'bare']);
    });

    test('a # inside quotes is not a comment', () {
      // "Foo #2 Panel" is a real product-name shape; naive splitting on # cuts
      // the criteria in half and the profile silently stops matching.
      expect(ScfgDocument.stripComment('output "Foo #2 Panel" enable'),
          'output "Foo #2 Panel" enable');
      expect(ScfgDocument.tokenise('output "Foo #2 Panel" enable').$2,
          ['Foo #2 Panel', 'enable']);
    });

    test('a trailing comment is stripped from the directive', () {
      final (name, params) = ScfgDocument.tokenise('output DP-1 enable # note');
      expect(name, 'output');
      expect(params, ['DP-1', 'enable']);
    });

    test('escapes survive', () {
      expect(ScfgDocument.tokenise(r"profile 'Nico\'s Desk' {").$2,
          ["Nico's Desk"]);
    });
  });

  test('comments stay attached to the directive that follows them', () {
    const src = '# about the profile\nprofile x {\n    # about the output\n'
        '    output DP-1 enable\n}\n';
    final doc = ScfgDocument.parse(src);
    expect(doc.nodes.single.leadingLines, ['# about the profile']);
    expect(doc.nodes.single.children.single.leadingLines,
        ['    # about the output']);
    expect(doc.render(), src);
  });

  test('an empty block keeps its braces', () {
    // `profile x {}` and `profile x` are not the same thing to kanshi.
    const src = 'profile x {\n}\n';
    expect(ScfgDocument.parse(src).render(), src);
  });
}
