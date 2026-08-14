/// Runs an `exec` line the way kanshi actually runs it, and reports what the
/// program on the other end received.
///
/// Every previous attempt to get a command past kanshi reasoned about the
/// quoting instead of measuring it, and was wrong for four releases. kanshi
/// 1.9 does not read the raw line any more; it parses the config with libscfg
/// and then re-escapes what libscfg unescaped, so that `sh` can unescape it
/// once more. The re-escaping covers exactly five characters
/// (`kanshi-1.9.0/config.c:270-276`):
///
/// ```c
/// if (ch == ' ' || ch == '\t' || ch == '\\' || ch == '\'' || ch == '"') {
///     fprintf(f, "\\");
/// }
/// ```
///
/// and the result goes to `execl("/bin/sh", "/bin/sh", "-c", cmd, NULL)`
/// (`main.c:118`). Everything else — `;` `(` `)` `|` `&` `$` `` ` `` — reaches
/// the shell bare and is interpreted. On the config this app was writing that
/// meant a `;`-joined chain was split into commands the shell could not find,
/// and a display whose EDID contains a bracket (`InfoVision Optoelectronics
/// (Kunshan) …`) killed the whole line with a syntax error before anything
/// ran at all.
///
/// So: no arguing about quoting. Write the line, run it through this, and
/// look at what arrives.
library;

import 'dart:io';

/// Splits one config line into scfg params, the way libscfg does: whitespace
/// separates, single and double quotes group, backslash escapes the next
/// character. Quotes and escapes are consumed — that is the "unescaping"
/// kanshi then has to undo.
List<String> scfgParams(String line) {
  final params = <String>[];
  final buf = StringBuffer();
  var started = false;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote == null && (ch == ' ' || ch == '\t')) {
      if (started) {
        params.add(buf.toString());
        buf.clear();
        started = false;
      }
      continue;
    }
    started = true;
    if (ch == r'\' && i + 1 < line.length) {
      buf.write(line[++i]);
      continue;
    }
    if (quote == null && (ch == '"' || ch == "'")) {
      quote = ch;
      continue;
    }
    if (ch == quote) {
      quote = null;
      continue;
    }
    buf.write(ch);
  }
  if (started) params.add(buf.toString());
  return params;
}

/// kanshi's re-escaping, character for character as in `parse_profile_exec`.
String kanshiShellCommand(List<String> params) {
  final out = StringBuffer();
  for (var i = 0; i < params.length; i++) {
    if (i > 0) out.write(' ');
    for (final ch in params[i].split('')) {
      if (ch == ' ' || ch == '\t' || ch == r'\' || ch == "'" || ch == '"') {
        out.write(r'\');
      }
      out.write(ch);
    }
  }
  return out.toString();
}

/// What the shell does with one `exec` directive.
class KanshiExecResult {
  /// One entry per program the shell actually started, each holding the
  /// program name followed by the arguments it received.
  final List<List<String>> invocations;

  /// Anything the shell complained about — a syntax error here means the
  /// whole line did nothing.
  final String stderr;
  final int exitCode;

  const KanshiExecResult(this.invocations, this.stderr, this.exitCode);

  bool get failed => exitCode != 0 || stderr.isNotEmpty;

  /// The single command sway would receive, for the common case of one
  /// `swaymsg` invocation with one argument.
  String? get swayCommand {
    final swaymsgs = invocations.where((i) => i.first == 'swaymsg').toList();
    if (swaymsgs.length != 1) return null;
    return swaymsgs.single.skip(1).join(' ');
  }

  /// Every sway command, in order, across however many invocations.
  List<String> get swayCommands => [
        for (final i in invocations)
          if (i.first == 'swaymsg') i.skip(1).join(' '),
      ];
}

/// Runs [execLine] (with or without its leading `exec `) through kanshi's
/// parsing and a real `/bin/sh`, with stubs on PATH standing in for the
/// programs it wants to start.
Future<KanshiExecResult> runAsKanshiWould(
  String execLine, {
  required Directory sandbox,
  List<String> stubs = const ['swaymsg', 'wl-mirror', 'pgrep', 'grep'],
}) async {
  final bin = Directory('${sandbox.path}/bin')..createSync(recursive: true);
  final log = '${sandbox.path}/invocations.log';
  File(log).writeAsStringSync('');
  for (final name in stubs) {
    final f = File('${bin.path}/$name');
    // Each stub records its own name and every argument as its own line, so
    // an argument containing spaces stays one argument in the transcript.
    f.writeAsStringSync('#!/bin/sh\n'
        'printf \'%s\\n\' "ARGV" "$name" "\$@" >> "$log"\n'
        'exit 0\n');
    Process.runSync('chmod', ['755', f.path]);
  }

  final body = execLine.trim().replaceFirst(RegExp(r'^exec\s+'), '');
  final cmd = kanshiShellCommand(scfgParams(body));
  final r = await Process.run('/bin/sh', ['-c', cmd], environment: {
    'PATH': '${bin.path}:/usr/bin:/bin',
    'HOME': sandbox.path,
  });

  final invocations = <List<String>>[];
  List<String>? current;
  for (final line in File(log).readAsLinesSync()) {
    if (line == 'ARGV') {
      if (current != null) invocations.add(current);
      current = <String>[];
      continue;
    }
    current?.add(line);
  }
  if (current != null) invocations.add(current);

  return KanshiExecResult(
    invocations,
    '${r.stderr}'.trim(),
    r.exitCode,
  );
}
