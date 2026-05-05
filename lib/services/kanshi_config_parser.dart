import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// Tokenises and parses the subset of kanshi config files this app produces
/// and reads. It is more permissive than the previous regex-only approach:
///
/// - profile names may be quoted ('…') or bare
/// - inline `#` and `//` comments are stripped
/// - braces are matched by counting (so per-profile blocks may contain inner
///   braces in `exec` lines, etc.)
/// - whitespace is normalised between tokens
class KanshiConfigParser {
  KanshiConfigParser._();

  static List<Profile> parse(String content) {
    final profiles = <Profile>[];
    final lines = _stripComments(content).split('\n');

    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        i++;
        continue;
      }

      final header = _matchProfileHeader(line);
      if (header == null) {
        i++;
        continue;
      }

      final block = StringBuffer();
      var depth = 0;
      var j = i;

      // Capture the opening brace if it's on the same line.
      depth += _countChar(line, '{');
      depth -= _countChar(line, '}');

      // Consume subsequent lines until the matching closing brace.
      var consumedHeader = false;
      while (j < lines.length) {
        if (j != i) {
          final ln = lines[j];
          block.writeln(ln);
          depth += _countChar(ln, '{');
          depth -= _countChar(ln, '}');
        } else if (line.contains('{')) {
          consumedHeader = true;
        }
        if (depth == 0 && consumedHeader) break;
        if (depth == 0 && j == i && !line.contains('{')) {
          // Header without brace on the same line — opening brace is on a
          // following line; loop continues.
          consumedHeader = true;
        }
        j++;
      }

      final blockText = block.toString();
      profiles.add(Profile(
        name: header,
        monitors: _applyMirrorExecs(_parseOutputs(blockText), blockText),
      ));
      i = j + 1;
    }

    return profiles;
  }

  /// Second-pass enrichment: extracts `exec wl-mirror …` directives from
  /// the profile block and stamps the matching destination output with
  /// `mirrorOf: <source>`. Tokenises each line so we are tolerant to
  /// either argument order (legacy `<src> --fullscreen-output <dst>` and
  /// the canonical `--fullscreen-output <dst> <src>` wl-mirror demands)
  /// and accept both quoted and bare ids. The destination is always the
  /// `--fullscreen-output` value; the source is the last positional that
  /// isn't a flag or a flag's value.
  static List<MonitorTileData> _applyMirrorExecs(
    List<MonitorTileData> outputs,
    String block,
  ) {
    if (outputs.isEmpty) return outputs;
    final byId = {for (final o in outputs) o.id: o};
    var dirty = false;
    for (final raw in block.split('\n')) {
      final line = raw.trim();
      final lower = line.toLowerCase();
      if (!lower.startsWith('exec') || !lower.contains('wl-mirror')) {
        continue;
      }
      final cmdIdx = lower.indexOf('wl-mirror');
      var rest = line.substring(cmdIdx + 'wl-mirror'.length).trim();
      if (rest.endsWith('&')) {
        rest = rest.substring(0, rest.length - 1).trim();
      }
      final tokens = _tokenizeShell(rest);
      // Identify which token positions are values to flags taking an
      // argument (e.g. --fullscreen-output VALUE). For wl-mirror flags
      // we treat the next token as a value when the flag is in the
      // known-takes-arg set.
      const takesArg = {
        '--fullscreen-output',
        '-F',
        '--scaling',
        '-s',
        '--backend',
        '-b',
        '--transform',
        '-t',
        '--region',
        '-r',
        '--title',
      };
      final flagValueIndices = <int>{};
      String? dst;
      for (var i = 0; i < tokens.length; i++) {
        final t = tokens[i];
        if (takesArg.contains(t) && i + 1 < tokens.length) {
          flagValueIndices.add(i + 1);
          if (t == '--fullscreen-output' || t == '-F') dst = tokens[i + 1];
        }
      }
      String? src;
      for (var i = tokens.length - 1; i >= 0; i--) {
        if (flagValueIndices.contains(i)) continue;
        if (tokens[i].startsWith('-')) continue;
        src = tokens[i];
        break;
      }
      if (dst == null || src == null) continue;
      final tile = byId[dst];
      if (tile == null) continue;
      byId[dst] = tile.copyWith(mirrorOf: src);
      dirty = true;
    }
    if (!dirty) return outputs;
    return [for (final o in outputs) byId[o.id] ?? o];
  }

  /// Minimal shell tokenizer: splits on whitespace but respects single
  /// quotes (so `'Some Brand 0'` stays one token).
  static List<String> _tokenizeShell(String s) {
    final tokens = <String>[];
    var cur = StringBuffer();
    var inQuote = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == "'") {
        inQuote = !inQuote;
      } else if (!inQuote && (ch == ' ' || ch == '\t')) {
        if (cur.isNotEmpty) {
          tokens.add(cur.toString());
          cur = StringBuffer();
        }
      } else {
        cur.write(ch);
      }
    }
    if (cur.isNotEmpty) tokens.add(cur.toString());
    return tokens;
  }

  /// Matches `profile foo {`, `profile 'foo bar' {`, `profile foo` (brace on
  /// next line). Returns the (un-quoted) name or `null` when the line is not
  /// a profile header.
  static String? _matchProfileHeader(String line) {
    final quoted =
        RegExp(r"^profile\s+'([^']+)'\s*\{?\s*$").firstMatch(line);
    if (quoted != null) return quoted.group(1)!.trim();
    final bare = RegExp(r'^profile\s+([^\s{]+)\s*\{?\s*$').firstMatch(line);
    if (bare != null) return bare.group(1)!.trim();
    return null;
  }

  static List<MonitorTileData> _parseOutputs(String block) {
    final outputs = <MonitorTileData>[];
    final outputRE = RegExp(
      r"output\s+(?:'([^']+)'|(\S+))\s+(enable|disable)([^\n]*)",
      caseSensitive: false,
    );

    for (final m in outputRE.allMatches(block)) {
      final name = (m.group(1) ?? m.group(2) ?? '').trim();
      if (name.isEmpty) continue;
      final state = m.group(3)!.toLowerCase();
      final rest = m.group(4) ?? '';
      final isEnabled = state == 'enable';

      final scaleMatch = RegExp(r'scale\s+([\d.]+)').firstMatch(rest);
      final modeMatch =
          RegExp(r'mode\s+(\d+)x(\d+)(?:@(\d+(?:\.\d+)?))?').firstMatch(rest);
      final transformMatch = RegExp(r'transform\s+(\S+)').firstMatch(rest);
      final positionMatch =
          RegExp(r'position\s+(-?\d+),(-?\d+)').firstMatch(rest);

      final scale =
          scaleMatch != null ? double.parse(scaleMatch.group(1)!) : 1.0;

      final baseW =
          modeMatch != null ? double.parse(modeMatch.group(1)!) : 1920.0;
      final baseH =
          modeMatch != null ? double.parse(modeMatch.group(2)!) : 1080.0;

      final transform = transformMatch?.group(1)?.trim() ?? 'normal';
      final rotation = switch (transform) {
        '90' => 90,
        '180' => 180,
        '270' => 270,
        'flipped-90' => 90,
        'flipped-180' => 180,
        'flipped-270' => 270,
        _ => 0,
      };

      final width = (rotation % 180 == 0) ? baseW : baseH;
      final height = (rotation % 180 == 0) ? baseH : baseW;
      final refresh = modeMatch != null
          ? (double.tryParse(modeMatch.group(3) ?? '') ?? 60.0)
          : 60.0;

      final resolution = '${width.toInt()}x${height.toInt()}';
      final orientation =
          (rotation % 180 == 0) ? 'landscape' : 'portrait';

      final posX = positionMatch != null
          ? double.parse(positionMatch.group(1)!)
          : 0.0;
      final posY = positionMatch != null
          ? double.parse(positionMatch.group(2)!)
          : 0.0;

      outputs.add(MonitorTileData(
        id: name,
        manufacturer: name,
        x: posX,
        y: posY,
        width: width,
        height: height,
        scale: scale,
        rotation: rotation,
        refresh: refresh,
        resolution: resolution,
        orientation: orientation,
        enabled: isEnabled,
      ));
    }

    return outputs;
  }

  /// Strips `#`-comments (full-line and inline) but preserves them inside
  /// single-quoted strings (so `output 'Foo # Bar'` stays intact).
  static String _stripComments(String content) {
    final out = StringBuffer();
    for (final raw in content.split('\n')) {
      var inSingle = false;
      var idx = 0;
      while (idx < raw.length) {
        final ch = raw[idx];
        if (ch == "'") inSingle = !inSingle;
        if (!inSingle && ch == '#') break;
        out.write(ch);
        idx++;
      }
      out.writeln();
    }
    return out.toString();
  }

  static int _countChar(String s, String ch) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] == ch) n++;
    }
    return n;
  }
}
