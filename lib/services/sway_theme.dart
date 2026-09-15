import 'dart:io';
import 'dart:ui' show Color;

import 'package:kanshi_gui/services/sway_config_files.dart';

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
      final content = await SwayConfigFiles.readFlattened(path);
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
      final line = SwayConfigFiles.stripInlineComment(raw);
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
