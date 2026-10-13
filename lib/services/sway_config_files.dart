import 'dart:convert';
import 'dart:io';

import 'package:kanshi_gui/services/process_runner.dart';

/// One logical line of a sway config, after includes have been followed.
class SwayConfigLine {
  /// The file the line is in.
  final String path;

  /// 1-based number of its first physical line in [path].
  final int number;

  /// The line as written, continuation lines joined.
  final String text;

  const SwayConfigLine(this.path, this.number, this.text);
}

/// Finds and reads the sway config the way sway itself does.
///
/// Shared by the accent-colour lookup and the kanshi autostart check, which
/// both need the same two answers: which file sway loaded, and what that file
/// pulls in.
class SwayConfigFiles {
  SwayConfigFiles._();

  /// sway's own search order when it is started without `-c`
  /// (`get_config_path` in sway/config.c): the first file that exists wins.
  static List<String> searchPaths(Map<String, String> environment) {
    final home = environment['HOME'] ?? '';
    final xdgRaw = environment['XDG_CONFIG_HOME'] ?? '';
    final xdg = xdgRaw.isNotEmpty
        ? xdgRaw
        : home.isNotEmpty
            ? '$home/.config'
            : '';
    return [
      if (home.isNotEmpty) '$home/.sway/config',
      if (xdg.isNotEmpty) '$xdg/sway/config',
      if (home.isNotEmpty) '$home/.i3/config',
      if (xdg.isNotEmpty) '$xdg/i3/config',
      '/etc/sway/config',
      '/etc/i3/config',
    ];
  }

  /// The config file the running sway loaded, or the one it would load.
  ///
  /// Asked of sway first: `get_version` names the file, and that is the only
  /// answer that is right for someone who starts sway with `-c`. Searched for
  /// only when sway cannot be asked.
  static Future<String?> locate({
    ProcessRunner runner = const DefaultProcessRunner(),
    Map<String, String>? environment,
  }) async {
    try {
      final r = await runner.run('swaymsg', ['-t', 'get_version'],
          timeout: const Duration(seconds: 2));
      if (r.exitCode == 0) {
        final json = jsonDecode('${r.stdout}');
        final name = json is Map ? json['loaded_config_file_name'] : null;
        if (name is String && name.isNotEmpty) return name;
      }
    } catch (_) {/* no sway to ask; search instead */}
    for (final p in searchPaths(environment ?? Platform.environment)) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// Every line of [path] and of what it includes, in the order sway reads
  /// them. `include` lines are replaced by the lines they pull in; a file
  /// included twice is read once.
  ///
  /// Throws when [path] itself cannot be read.
  static Future<List<SwayConfigLine>> readLines(String path) =>
      _read(File(path), <String>{});

  /// The same, as one string — for callers that only scan text.
  static Future<String> readFlattened(String path) async =>
      (await readLines(path)).map((l) => l.text).join('\n');

  static Future<List<SwayConfigLine>> _read(File file, Set<String> seen) async {
    final canonical = file.absolute.path;
    if (!seen.add(canonical)) return const [];
    final physical = const LineSplitter().convert(await file.readAsString());
    final out = <SwayConfigLine>[];
    var i = 0;
    while (i < physical.length) {
      final first = i;
      var text = physical[i];
      // sway joins a line that ends in a backslash with the next one; a
      // multi-line `exec … && \` is one command.
      while (text.endsWith(r'\') && i + 1 < physical.length) {
        i++;
        text = text.substring(0, text.length - 1) + physical[i];
      }
      i++;
      final line = stripInlineComment(text).trim();
      if (line.startsWith('include ')) {
        final pattern = line.substring('include '.length).trim();
        for (final inc in await resolveIncludes(pattern, file.parent)) {
          out.addAll(await _read(inc, seen));
        }
        continue;
      }
      out.add(SwayConfigLine(canonical, first + 1, text));
    }
    return out;
  }

  /// Whether this user can append to [path]. Opening for append writes
  /// nothing; it only asks the kernel. A sway running from `/etc/sway/config`
  /// is not something to edit from here.
  static Future<bool> isWritable(String path) async {
    try {
      final f = await File(await File(path).resolveSymbolicLinks())
          .open(mode: FileMode.append);
      await f.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Appends [lines] under the comment [marker] to the sway config at [path].
  ///
  /// Appended, not rewritten: through a symlink (dotfile managers link the
  /// config into place) and with its permissions untouched, and nothing the
  /// user wrote is moved. Returns null on success and a sentence for the user
  /// otherwise.
  static Future<String?> appendBlock(
      String path, String marker, List<String> lines) async {
    try {
      final target = File(await File(path).resolveSymbolicLinks());
      final before = await target.readAsString();
      final block = StringBuffer();
      if (before.isNotEmpty && !before.endsWith('\n')) block.write('\n');
      block.write('\n$marker\n');
      for (final l in lines) {
        block.write('$l\n');
      }
      await target.writeAsString(block.toString(),
          mode: FileMode.append, flush: true);
      return null;
    } on FileSystemException catch (e) {
      return 'Could not write $path: ${e.osError?.message ?? e.message}.';
    }
  }

  /// Takes out what [appendBlock] put in: the lines of [ours] (each a whole
  /// physical line, by 1-based number per file), the [marker] directly above
  /// them, and the blank line [appendBlock] wrote above that.
  ///
  /// Only those. A line the user changed no longer matches and was never in
  /// [ours]; a marker without our lines under it is left where it is.
  /// Returns null on success and a sentence for the user otherwise.
  static Future<String?> removeBlock(
      String marker, List<SwayConfigLine> ours) async {
    final byFile = <String, Set<int>>{};
    for (final l in ours) {
      (byFile[l.path] ??= <int>{}).add(l.number);
    }
    for (final entry in byFile.entries) {
      try {
        final target = File(await File(entry.key).resolveSymbolicLinks());
        final raw = await target.readAsString();
        final physical = raw.split('\n');
        final drop = <int>{for (final n in entry.value) n - 1};
        final first = drop.reduce((a, b) => a < b ? a : b);
        if (first > 0 && physical[first - 1].trim() == marker) {
          drop.add(first - 1);
          if (first > 1 && physical[first - 2].trim().isEmpty) {
            drop.add(first - 2);
          }
        }
        final kept = [
          for (var i = 0; i < physical.length; i++)
            if (!drop.contains(i)) physical[i],
        ];
        // In place, so a symlinked config stays a symlink and keeps its
        // permissions.
        await target.writeAsString(kept.join('\n'), flush: true);
      } on FileSystemException catch (e) {
        return 'Could not write ${entry.key}: '
            '${e.osError?.message ?? e.message}.';
      }
    }
    return null;
  }

  /// Strips `# …` after the first space-preceded `#`. Sway treats `#` after
  /// whitespace as a comment delimiter; the leading `#` of a colour literal
  /// (`#b162d5`) is NOT preceded by whitespace inside a token, so we look for
  /// ` #` (space + hash) only.
  static String stripInlineComment(String line) {
    final idx = line.indexOf(' #');
    if (idx == -1) return line;
    // Heuristic: if the `#` is followed by 6 or 8 hex digits and a
    // word boundary, it's a colour, not a comment. Otherwise comment.
    final after = line.substring(idx + 2);
    final isHex = RegExp(r'^[0-9a-fA-F]{6,8}\b').hasMatch(after);
    if (isHex) return line;
    return line.substring(0, idx);
  }

  /// The files an `include` pattern names, sorted like a shell glob.
  static Future<List<File>> resolveIncludes(
    String pattern,
    Directory base,
  ) async {
    final expanded = _expandEnvironment(pattern);
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

  /// `~` and `$NAME` / `${NAME}`, which sway expands in include paths
  /// (wordexp). An unset variable is left as written.
  static String _expandEnvironment(String p) {
    final env = Platform.environment;
    var out = p;
    if (out.startsWith('~')) {
      final home = env['HOME'];
      if (home != null && home.isNotEmpty) out = '$home${out.substring(1)}';
    }
    return out.replaceAllMapped(
      RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)'),
      (m) => env[m.group(1) ?? m.group(2)!] ?? m.group(0)!,
    );
  }
}
