import 'dart:io';
import 'dart:ui' show Color;

/// Reads the user's sway config and extracts the focused-window border
/// colour from the `client.focused` directive — the colour sway draws
/// around the active window and that waybar themes typically copy as
/// the workspace-highlight accent. Returns null on any failure (no
/// config, no `client.focused`, malformed colour, unresolved variable)
/// so callers can fall back to a hard-coded default.
///
/// Lookup order:
///   1. `$XDG_CONFIG_HOME/sway/config` if XDG_CONFIG_HOME is set
///   2. `$HOME/.config/sway/config` otherwise
///
/// Sway config syntax we handle:
///   - `set $name #rrggbb` or `set $name #rrggbbaa` defines a variable
///   - `include <pattern>` pulls in another file (glob, relative to
///     the including file's directory or absolute)
///   - `client.focused <border> <bg> <text> <indicator> <child_border>`
///     — we take the first colour (the active border / accent)
///   - `# …` line comments and inline comments after `#`
///
/// Variable resolution is single-pass: a variable used in
/// `client.focused` must resolve to a literal hex value (we do not
/// chase `set $a $b` chains — sway itself does not require them and
/// real configs in the wild don't use them).
class SwayThemeReader {
  SwayThemeReader._();

  /// Read the user's config and return the focused-window border
  /// colour, or null if it can't be determined safely. All I/O errors
  /// are swallowed — this is a best-effort theming hook, never a hard
  /// dependency.
  static Future<Color?> readAccentColor({String? configPath}) async {
    try {
      final path = configPath ?? _defaultConfigPath();
      if (path == null) return null;
      final file = File(path);
      if (!await file.exists()) return null;
      final content = await _readWithIncludes(file, <String>{});
      return _extractAccent(content);
    } catch (_) {
      return null;
    }
  }

  static String? _defaultConfigPath() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return '$xdg/sway/config';
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    return '$home/.config/sway/config';
  }

  /// Concatenates the file's contents with the contents of every file
  /// it `include`s (recursively). [seen] tracks already-resolved paths
  /// so a self-referential include can't blow the stack.
  static Future<String> _readWithIncludes(
    File file,
    Set<String> seen,
  ) async {
    final canonical = file.absolute.path;
    if (seen.contains(canonical)) return '';
    seen.add(canonical);
    final raw = await file.readAsString();
    final buf = StringBuffer();
    final dir = file.parent;
    for (final rawLine in raw.split('\n')) {
      final line = _stripInlineComment(rawLine).trim();
      if (line.startsWith('include ')) {
        final pattern = line.substring('include '.length).trim();
        for (final inc in await _resolveIncludes(pattern, dir)) {
          buf.writeln(await _readWithIncludes(inc, seen));
        }
        continue;
      }
      buf.writeln(rawLine);
    }
    return buf.toString();
  }

  /// Strips `# …` after the first space-preceded `#`. Sway treats
  /// `#` after whitespace as a comment delimiter; the leading `#` of
  /// a colour literal (`#b162d5`) is NOT preceded by whitespace inside
  /// a token, so we look for ` #` (space + hash) only.
  static String _stripInlineComment(String line) {
    final idx = line.indexOf(' #');
    if (idx == -1) return line;
    // Heuristic: if the `#` is followed by 6 or 8 hex digits and a
    // word boundary, it's a colour, not a comment. Otherwise comment.
    final after = line.substring(idx + 2);
    final isHex = RegExp(r'^[0-9a-fA-F]{6,8}\b').hasMatch(after);
    if (isHex) return line;
    return line.substring(0, idx);
  }

  static Future<List<File>> _resolveIncludes(
    String pattern,
    Directory base,
  ) async {
    final expanded = _expandHome(pattern);
    final isAbs = expanded.startsWith('/');
    final basePath = isAbs ? '' : '${base.path}/';
    final fullPattern = '$basePath$expanded';
    // Cheap glob: only handle `*` in the basename — sway configs in
    // the wild use patterns like `~/.config/sway/config.d/*` or a
    // bare path. Anything more elaborate falls through as a literal.
    if (!fullPattern.contains('*')) {
      final f = File(fullPattern);
      return await f.exists() ? [f] : <File>[];
    }
    final lastSlash = fullPattern.lastIndexOf('/');
    final dirPath =
        lastSlash >= 0 ? fullPattern.substring(0, lastSlash) : '.';
    final globPart =
        lastSlash >= 0 ? fullPattern.substring(lastSlash + 1) : fullPattern;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return <File>[];
    final regex = RegExp(
      '^${RegExp.escape(globPart).replaceAll(r'\*', '.*')}\$',
    );
    final hits = <File>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (regex.hasMatch(name)) hits.add(entity);
    }
    hits.sort((a, b) => a.path.compareTo(b.path));
    return hits;
  }

  static String _expandHome(String p) {
    if (!p.startsWith('~')) return p;
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return p;
    return '$home${p.substring(1)}';
  }

  /// Walks the (already include-flattened) config text. Builds a
  /// variable map from `set $name #color` lines, then locates the
  /// `client.focused` directive and returns the first token resolved
  /// to a Color. Returns null if no usable value is present.
  static Color? _extractAccent(String content) {
    final vars = <String, String>{};
    final setRe = RegExp(
      r'^\s*set\s+\$([A-Za-z_][A-Za-z0-9_]*)\s+(\S+)\s*$',
    );
    final focusedRe =
        RegExp(r'^\s*client\.focused\s+(\S+)(?:\s|$)', multiLine: false);
    String? focusedToken;
    for (final raw in content.split('\n')) {
      final line = _stripInlineComment(raw);
      final m = setRe.firstMatch(line);
      if (m != null) {
        vars[m.group(1)!] = m.group(2)!;
        continue;
      }
      // Only capture the FIRST client.focused line — sway uses the
      // last definition wins, so we keep updating instead.
      final f = focusedRe.firstMatch(line);
      if (f != null) focusedToken = f.group(1);
    }
    if (focusedToken == null) return null;
    return _resolveToken(focusedToken, vars);
  }

  static Color? _resolveToken(String token, Map<String, String> vars) {
    var value = token;
    if (value.startsWith(r'$')) {
      final name = value.substring(1);
      final resolved = vars[name];
      if (resolved == null) return null;
      value = resolved;
    }
    return _parseHex(value);
  }

  /// Parses `#rrggbb` or `#rrggbbaa` to a [Color]. Returns null on
  /// anything else.
  static Color? _parseHex(String hex) {
    if (!hex.startsWith('#')) return null;
    final body = hex.substring(1);
    if (body.length != 6 && body.length != 8) return null;
    final n = int.tryParse(body, radix: 16);
    if (n == null) return null;
    if (body.length == 6) {
      return Color(0xFF000000 | n);
    }
    // sway's order in `client.*` directives is `#rrggbbaa`, but
    // Flutter's Color stores ARGB. Move alpha to the high byte.
    final rgb = n >> 8;
    final alpha = n & 0xFF;
    return Color((alpha << 24) | rgb);
  }
}
