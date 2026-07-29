// Pure Dart. No Flutter, no dart:io.

import 'package:kanshi_gui/domain/kanshi/scfg.dart';

/// Edits a kanshi config in place, rather than re-rendering it.
///
/// This is the difference between "the app writes its own dialect" and "the
/// app edits the user's file". Only the directives kanshi_gui owns are
/// touched: the `output` lines of profiles it manages, and its own
/// `# kanshi_gui:…` annotations. Everything else — `include`, `alias`, global
/// `output` defaults, hand-written `exec` lines, `adaptive_sync`, comments,
/// blank lines, indentation, and any directive invented after this code was
/// written — passes through byte for byte, because it is emitted from the
/// source text rather than from a model.
class KanshiDocument {
  final ScfgDocument doc;

  const KanshiDocument(this.doc);

  static KanshiDocument parse(String source) =>
      KanshiDocument(ScfgDocument.parse(source));

  String render() => doc.render();

  /// Names of the profiles present, in file order. An unnamed profile is
  /// reported as the empty string.
  List<String> get profileNames => [
        for (final n in doc.nodes)
          if (n.name == 'profile') n.params.isEmpty ? '' : n.params.first,
      ];

  /// Replaces the `output` lines of the profile named [name].
  ///
  /// [outputLines] are complete source lines including indentation. Anything
  /// else inside the profile — exec lines, comments, directives this app does
  /// not model — keeps its position relative to the block, so a user's
  /// hand-written `exec` survives an edit to the geometry above it.
  ///
  /// [annotationPrefix] identifies the app's own comment annotations so they
  /// can be replaced wholesale; comments that are not ours are left alone.
  ///
  /// Returns false when no such profile exists.
  bool replaceOutputs(
    String name, {
    required List<String> outputLines,
    required List<String> annotationLines,
    String annotationPrefix = '# kanshi_gui:',
  }) {
    final idx = _indexOfProfile(name);
    if (idx == -1) return false;
    final node = doc.nodes[idx];

    final kept = <ScfgNode>[];
    // Comments the user wrote above an output line belong to that output, so
    // replacing the line must not take them with it. They are salvaged and
    // re-emitted above the new lines.
    final salvaged = <String>[];
    for (final child in node.children) {
      // Our own annotation comments parse as directive-less nodes; they are
      // replaced wholesale rather than accumulating a copy per save.
      if (_isOurs(child.rawLine, annotationPrefix)) {
        salvaged.addAll(_theirComments(child.leadingLines, annotationPrefix));
        continue;
      }
      if (child.name == 'output' && !child.hasBlock) {
        salvaged.addAll(_theirComments(child.leadingLines, annotationPrefix));
        continue;
      }
      // A braced output block is still an output directive. It is kept
      // because this app cannot express one, and dropping it would lose the
      // user's mode and position.
      kept.add(_withoutOurAnnotations(child, annotationPrefix));
    }

    final rebuilt = <ScfgNode>[
      for (var i = 0; i < outputLines.length; i++)
        _lineNode(outputLines[i], leading: i == 0 ? salvaged : const []),
      for (final line in annotationLines) _lineNode(line),
      ...kept,
    ];
    doc.nodes[idx] = node.copyWith(
      children: rebuilt,
      // Annotations that ended up after the last directive are ours to
      // replace too; anything else the user wrote there stays.
      trailingLines: [
        for (final line in node.trailingLines)
          if (!_isOurs(line, annotationPrefix)) line,
      ],
    );
    return true;
  }

  /// Appends a whole profile, source text and all.
  void appendProfile(List<String> lines) {
    final sub = ScfgDocument.parse(lines.join('\n'));
    doc.nodes.addAll(sub.nodes);
  }

  /// Removes the profile named [name]. Returns false when it is not there.
  bool removeProfile(String name) {
    final idx = _indexOfProfile(name);
    if (idx == -1) return false;
    doc.nodes.removeAt(idx);
    return true;
  }

  /// True when the document holds anything this app cannot re-create from its
  /// model, so a caller can tell "I edited your file" from "I rewrote it".
  bool get hasForeignContent {
    for (final node in doc.nodes) {
      if (node.name != 'profile') return true;
      if (node.params.isEmpty) return true; // unnamed profile
      for (final child in node.children) {
        if (child.name == 'output' && child.hasBlock) return true;
        if (child.name == '...output') return true;
      }
    }
    return false;
  }

  int _indexOfProfile(String name) => doc.nodes.indexWhere(
        (n) =>
            n.name == 'profile' &&
            (n.params.isEmpty ? '' : n.params.first) == name,
      );

  /// Drops the leading comment lines this app wrote, so they are replaced
  /// rather than accumulating one copy per save. Comments that are not ours
  /// stay exactly where the user put them.
  static ScfgNode _withoutOurAnnotations(ScfgNode node, String prefix) {
    if (node.leadingLines.isEmpty) return node;
    final kept = [
      for (final line in node.leadingLines)
        if (!line.trimLeft().startsWith(prefix)) line,
    ];
    return kept.length == node.leadingLines.length
        ? node
        : node.copyWith(leadingLines: kept);
  }

  static bool _isOurs(String line, String prefix) =>
      line.trimLeft().startsWith(prefix);

  /// The comment lines in [lines] that this app did not write.
  static List<String> _theirComments(List<String> lines, String prefix) => [
        for (final line in lines)
          if (!_isOurs(line, prefix) && line.trim().isNotEmpty) line,
      ];

  static ScfgNode _lineNode(String line, {List<String> leading = const []}) {
    final (name, params) = ScfgDocument.tokenise(line);
    return ScfgNode(
        name: name, params: params, rawLine: line, leadingLines: leading);
  }
}
