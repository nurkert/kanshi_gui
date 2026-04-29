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

      profiles.add(Profile(
        name: header,
        monitors: _parseOutputs(block.toString()),
      ));
      i = j + 1;
    }

    return profiles;
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
