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

  /// Replaces everything inside profile [name] that this app owns with
  /// [replacement], leaving everything else in place and in order.
  ///
  /// Ownership is deliberately explicit rather than "whatever we recognise":
  /// the app owns flat `output` directives, its own `# kanshi_gui:`
  /// annotations, and the `exec` lines it generates itself. A user's own
  /// `exec`, a braced `output { … }` block it cannot express, an
  /// `adaptive_sync` line and every other directive belong to the user and
  /// survive untouched — which is the entire difference between editing
  /// someone's file and overwriting it.
  bool replaceManagedChildren(
    String name,
    List<ScfgNode> replacement, {
    String annotationPrefix = '# kanshi_gui:',
  }) {
    final idx = _indexOfProfile(name);
    if (idx == -1) return false;
    final node = doc.nodes[idx];

    final kept = <ScfgNode>[];
    final salvaged = <String>[];
    // Output directives the app is about to replace, by criteria, so any
    // parameter it does not model can be carried across.
    final oldOutputs = <String, ScfgNode>{};
    for (final child in node.children) {
      if (_isManaged(child, annotationPrefix)) {
        if (child.name == 'output' && child.params.isNotEmpty) {
          oldOutputs[child.params.first] = child;
        }
        salvaged.addAll(_theirComments(child.leadingLines, annotationPrefix));
        continue;
      }
      kept.add(_withoutOurAnnotations(child, annotationPrefix));
    }

    final rebuilt = <ScfgNode>[
      for (var i = 0; i < replacement.length; i++)
        _mergeForeignParams(
          i == 0 && salvaged.isNotEmpty
              ? replacement[i].copyWith(
                  leadingLines: [...salvaged, ...replacement[i].leadingLines])
              : replacement[i],
          oldOutputs,
        ),
      ...kept,
    ];
    doc.nodes[idx] = node.copyWith(
      children: rebuilt,
      trailingLines: [
        for (final line in node.trailingLines)
          if (!_isOurs(line, annotationPrefix)) line,
      ],
    );
    return true;
  }

  /// Output directives this app models. Anything else on an `output` line
  /// belongs to the user and is carried across when the line is rewritten.
  static const _modelledOutputKeys = {
    'enable',
    'disable',
    'scale',
    'mode',
    'transform',
    'position',
  };

  /// Re-attaches parameters the app does not model to a rewritten line.
  ///
  /// `output X enable adaptive_sync on` is one directive, not two: replacing
  /// the geometry would otherwise silently drop the adaptive-sync setting,
  /// which is a real preference the app simply has no field for. It cannot
  /// round-trip what it does not model unless it copies it across verbatim.
  static ScfgNode _mergeForeignParams(
    ScfgNode fresh,
    Map<String, ScfgNode> oldOutputs,
  ) {
    if (fresh.name != 'output' || fresh.params.isEmpty) return fresh;
    final old = oldOutputs[fresh.params.first];
    if (old == null) return fresh;

    final extra = <String>[];
    var i = 1;
    while (i < old.params.length) {
      final key = old.params[i];
      if (_modelledOutputKeys.contains(key)) {
        i += (key == 'enable' || key == 'disable') ? 1 : 2;
        continue;
      }
      // An unmodelled directive: take it and its value when it has one.
      extra.add(key);
      if (i + 1 < old.params.length &&
          !_modelledOutputKeys.contains(old.params[i + 1])) {
        extra.add(old.params[i + 1]);
        i += 2;
      } else {
        i += 1;
      }
    }
    if (extra.isEmpty) return fresh;
    return fresh.copyWith(
      params: [...fresh.params, ...extra],
      rawLine: '${fresh.rawLine} ${extra.join(' ')}',
    );
  }

  /// Whether this app wrote [child], and may therefore replace it.
  static bool _isManaged(ScfgNode child, String annotationPrefix) {
    if (_isOurs(child.rawLine, annotationPrefix)) return true;
    // A braced output block is NOT ours: the app cannot express one, so it
    // was written by hand and dropping it would lose the user's mode.
    if (child.name == 'output' && !child.hasBlock) return true;
    if (child.name != 'exec') return false;
    // The exec lines the writer generates, and only those. A user's own exec
    // — the reason this distinction exists — stays where they put it.
    final body = child.rawLine.trim();
    // The workspace chain is recognised by its shape, not by the number it
    // ends on. It used to be matched on the literal `workspace number 1`,
    // which a chain built from an observed map that happened not to include
    // workspace 1 does not contain — so the app failed to recognise its own
    // line, kept it, and wrote a second one beside it. Two exec chains giving
    // sway contradictory homes is worse than either of them.
    // Since 2.1.1 the workspace bindings are one `exec swaymsg workspace N
    // output …` per line instead of one `;`-joined chain — kanshi hands exec
    // lines to /bin/sh, which ate the separators. Both shapes have to be
    // recognised: the old one so an existing config gets replaced rather than
    // doubled, the new one so the app keeps recognising what it wrote today.
    return RegExp(r'^(?:exec\s+)?swaymsg\s+workspace\s+\d+\s+output\s')
            .hasMatch(body) ||
        (body.contains('workspace number ') &&
            body.contains('move workspace to output')) ||
        body.contains('workspace number 1') ||
        body.contains('.current_kanshi_profile') ||
        body.contains('wl-mirror');
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
