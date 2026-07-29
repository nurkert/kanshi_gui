// Pure Dart. No Flutter, no dart:io.

/// A parser for scfg, the configuration language kanshi uses.
///
/// The point of an AST rather than line regexes: a config the app only
/// partially understands must still survive being written back. The previous
/// parser modelled the subset kanshi_gui itself emits and the writer
/// re-rendered the whole file from that model, so anything it had not
/// recognised — an `include`, an `alias`, a hand-written `exec`, a braced
/// output block, an `adaptive_sync` line — was deleted on the first save.
///
/// Here every directive keeps its source text. Nodes the app does not touch
/// are re-emitted verbatim, byte for byte, including their comments and their
/// indentation. The app can only lose what it deliberately rewrites.
library;

/// One directive: a name, its parameters, and optionally a block.
class ScfgNode {
  /// Directive name, e.g. `profile`, `output`, `include`.
  final String name;

  /// Parameters with their quoting removed.
  final List<String> params;

  /// Child directives when this node had a `{ … }` block, else empty.
  final List<ScfgNode> children;

  /// Whether the source wrote a block, even an empty one. A directive that
  /// had `{}` must keep it: dropping the braces changes what kanshi's
  /// defaults mean.
  final bool hasBlock;

  /// The exact source text of this node's own line, indentation included.
  /// Everything the app has not rewritten is emitted from this.
  final String rawLine;

  /// Comment and blank lines that preceded this directive. They belong to it
  /// so a node can move without its comment being orphaned.
  final List<String> leadingLines;

  /// Comment and blank lines between the last child and the closing brace.
  /// Without somewhere to put these, a comment at the end of a block is
  /// silently dropped on the first save — the exact class of loss an AST is
  /// here to prevent.
  final List<String> trailingLines;

  const ScfgNode({
    required this.name,
    required this.params,
    this.children = const [],
    this.hasBlock = false,
    this.rawLine = '',
    this.leadingLines = const [],
    this.trailingLines = const [],
  });

  ScfgNode copyWith({
    String? name,
    List<String>? params,
    List<ScfgNode>? children,
    bool? hasBlock,
    String? rawLine,
    List<String>? leadingLines,
    List<String>? trailingLines,
  }) =>
      ScfgNode(
        name: name ?? this.name,
        params: params ?? this.params,
        children: children ?? this.children,
        hasBlock: hasBlock ?? this.hasBlock,
        rawLine: rawLine ?? this.rawLine,
        leadingLines: leadingLines ?? this.leadingLines,
        trailingLines: trailingLines ?? this.trailingLines,
      );

  @override
  String toString() =>
      'ScfgNode($name, ${params.length} params, ${children.length} children)';
}

/// A parsed scfg document that can be rendered back out.
class ScfgDocument {
  final List<ScfgNode> nodes;

  /// Comment or blank lines after the last directive.
  final List<String> trailingLines;

  const ScfgDocument(this.nodes, {this.trailingLines = const []});

  static ScfgDocument parse(String source) {
    final lines = source.split('\n');
    // A trailing newline produces an empty final element; it is reinstated on
    // render, so drop it here rather than treating it as a blank line.
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    final parser = _Parser(lines);
    final nodes = parser.parseUntilClose(depthClosing: false);
    return ScfgDocument(nodes, trailingLines: parser.takePending());
  }

  String render() {
    final out = StringBuffer();
    for (final node in nodes) {
      _renderNode(out, node);
    }
    for (final line in trailingLines) {
      out.writeln(line);
    }
    return out.toString();
  }

  static void _renderNode(StringBuffer out, ScfgNode node) {
    for (final line in node.leadingLines) {
      out.writeln(line);
    }
    out.writeln(node.rawLine);
    if (!node.hasBlock) return;
    for (final child in node.children) {
      _renderNode(out, child);
    }
    for (final line in node.trailingLines) {
      out.writeln(line);
    }
    // The closing brace is reconstructed at the indentation of the opener, so
    // a rewritten block still lines up with its neighbours.
    final indent = RegExp(r'^\s*').firstMatch(node.rawLine)?.group(0) ?? '';
    out.writeln('$indent}');
  }

  /// Splits a directive line into its name and parameters.
  ///
  /// Handles the three quoting styles that occur in the wild: `"double"`,
  /// which is what scfg documents; `'single'`, which this app has always
  /// written and kanshi accepts; and bare words.
  static (String, List<String>) tokenise(String line) {
    final body = stripComment(line).trim();
    if (body.isEmpty) return ('', const []);
    final tokens = <String>[];
    final buf = StringBuffer();
    String? quote;
    var escaped = false;
    var started = false;

    for (var i = 0; i < body.length; i++) {
      final ch = body[i];
      if (escaped) {
        buf.write(ch);
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        started = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else {
          buf.write(ch);
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        started = true;
        continue;
      }
      if (ch == '{' || ch == '}') break;
      if (ch.trim().isEmpty) {
        if (started) {
          tokens.add(buf.toString());
          buf.clear();
          started = false;
        }
        continue;
      }
      buf.write(ch);
      started = true;
    }
    if (started) tokens.add(buf.toString());
    if (tokens.isEmpty) return ('', const []);
    return (tokens.first, tokens.sublist(1));
  }

  /// Removes a trailing `#` comment, respecting quotes.
  ///
  /// Naive splitting on `#` would truncate `output "Foo #2 Panel"`, which is
  /// a real product name shape.
  static String stripComment(String line) {
    String? quote;
    var escaped = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch == r'\') {
        escaped = true;
        continue;
      }
      if (quote != null) {
        if (ch == quote) quote = null;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      if (ch == '#') return line.substring(0, i);
    }
    return line;
  }

  /// True when [line] carries no directive — blank, or comment only.
  static bool isBlankOrComment(String line) =>
      stripComment(line).trim().isEmpty;
}

class _Parser {
  final List<String> lines;
  int i = 0;
  List<String> pending = [];

  _Parser(this.lines);

  List<String> takePending() {
    final p = pending;
    pending = [];
    return p;
  }

  List<ScfgNode> parseUntilClose({required bool depthClosing}) {
    final nodes = <ScfgNode>[];
    while (i < lines.length) {
      final line = lines[i];
      final body = ScfgDocument.stripComment(line).trim();

      if (body.isEmpty) {
        pending.add(line);
        i++;
        continue;
      }
      if (body == '}') {
        if (depthClosing) {
          i++;
          return nodes;
        }
        // A stray closing brace at top level: keep it verbatim rather than
        // guessing at a repair.
        pending.add(line);
        i++;
        continue;
      }

      final (name, params) = ScfgDocument.tokenise(line);
      final opensBlock = body.endsWith('{');
      final leading = takePending();
      i++;

      if (opensBlock) {
        final children = parseUntilClose(depthClosing: true);
        // Whatever the block's last directive did not claim belongs to the
        // block, not to whatever comes after the closing brace.
        nodes.add(ScfgNode(
          name: name,
          params: params,
          children: children,
          hasBlock: true,
          rawLine: line,
          leadingLines: leading,
          trailingLines: takePending(),
        ));
      } else {
        nodes.add(ScfgNode(
          name: name,
          params: params,
          rawLine: line,
          leadingLines: leading,
        ));
      }
    }
    return nodes;
  }
}
