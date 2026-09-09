import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// What [KanshiConfigParser.diagnose] found in a config file, compared with
/// what the parser was able to turn into [Profile]s.
///
/// The parser models the subset of kanshi's DSL that the GUI writes. Anything
/// outside that subset is not an error — kanshi accepts it happily — but the
/// GUI must know it did not understand the file, because [KanshiConfigWriter]
/// re-renders the whole config from the model and would drop whatever the
/// parser never saw.
class KanshiConfigDiagnostics {
  /// `profile` headers present in the file, named or not.
  final int profilesInFile;

  /// Profiles the parser produced.
  final int profilesParsed;

  /// `output` / `...output` directives inside profile blocks.
  final int outputsInFile;

  /// Monitors the parser produced across all profiles.
  final int outputsParsed;

  /// Global-scope `output <criteria> …` default lines. The model has no place
  /// for them, so they do not appear in the GUI — but they are preserved.
  final int globalOutputDefaults;

  const KanshiConfigDiagnostics({
    required this.profilesInFile,
    required this.profilesParsed,
    required this.outputsInFile,
    required this.outputsParsed,
    required this.globalOutputDefaults,
  });

  /// True when everything in the file made it into the model, so rendering
  /// the model back cannot lose a profile or an output.
  bool get isLossless =>
      profilesInFile == profilesParsed &&
      outputsInFile == outputsParsed &&
      globalOutputDefaults == 0;

  /// Human-readable summary of what would be lost, or null when nothing is.
  String? get lossDescription {
    if (isLossless) return null;
    final parts = <String>[];
    if (profilesInFile != profilesParsed) {
      parts.add('${profilesInFile - profilesParsed} of $profilesInFile '
          'profiles');
    }
    if (outputsInFile != outputsParsed) {
      parts.add('${outputsInFile - outputsParsed} of $outputsInFile '
          'output lines');
    }
    if (globalOutputDefaults > 0) {
      parts.add('$globalOutputDefaults global output default'
          '${globalOutputDefaults == 1 ? '' : 's'}');
    }
    return parts.join(' and ');
  }

  @override
  String toString() => 'KanshiConfigDiagnostics(profiles '
      '$profilesParsed/$profilesInFile, outputs $outputsParsed/$outputsInFile, '
      'globalDefaults $globalOutputDefaults)';
}

/// Tokenises and parses the subset of kanshi config files this app produces
/// and reads. It is more permissive than the previous regex-only approach:
///
/// - profile names may be quoted ('…') or bare, with `\'` escapes
/// - output criteria may be 'single-quoted', "double-quoted" or bare
/// - inline `#` and `//` comments are stripped
/// - braces are matched by counting (so per-profile blocks may contain inner
///   braces in `exec` lines, etc.)
/// - whitespace is normalised between tokens
///
/// It does NOT model all of kanshi's DSL. That is no longer dangerous: since
/// M9 the save edits the document in place through [KanshiDocument] and only
/// replaces the directives this app owns, so what the parser cannot read is
/// preserved rather than deleted. [diagnose] still reports the gap, because
/// the app should be able to say what it cannot show.
class KanshiConfigParser {
  KanshiConfigParser._();

  /// Counts what the file contains and what [parse] managed to read from it.
  ///
  /// Reports what the app cannot show the user. It was once the basis of a
  /// save-refusal gate — a hand-written config using kanshi's optional-`enable`
  /// form parsed as zero monitors per profile, the writer skipped every empty
  /// profile, and the first save replaced the file with an empty one. Since M9
  /// the save preserves what it cannot read, so this is informational.
  static KanshiConfigDiagnostics diagnose(String content) {
    final stripped = _stripComments(content).split('\n');
    final profileHeader = RegExp(r'^\s*profile\b');
    final outputLine = RegExp(r'^\s*(?:\.\.\.)?output\s+\S');

    var profilesInFile = 0;
    var outputsInFile = 0;
    var globalOutputDefaults = 0;
    var depth = 0;

    for (final line in stripped) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (depth == 0 && profileHeader.hasMatch(trimmed)) {
        profilesInFile++;
      } else if (outputLine.hasMatch(trimmed)) {
        if (depth > 0) {
          outputsInFile++;
        } else {
          globalOutputDefaults++;
        }
      }
      depth += _countChar(line, '{') - _countChar(line, '}');
      if (depth < 0) depth = 0;
    }

    final parsed = parse(content);
    return KanshiConfigDiagnostics(
      profilesInFile: profilesInFile,
      profilesParsed: parsed.length,
      outputsInFile: outputsInFile,
      outputsParsed:
          parsed.fold<int>(0, (n, p) => n + p.monitors.length),
      globalOutputDefaults: globalOutputDefaults,
    );
  }

  static List<Profile> parse(String content) {
    final profiles = <Profile>[];
    // Rank and mirror annotations live inside `# kanshi_gui:…` comments,
    // so pull them off the raw content before the comment stripper drops
    // them. Keyed by profile name → output id → value.
    final rankByProfile = _extractRankComments(content);
    final mirrorByProfile = _extractMirrorComments(content);
    final edidByProfile = _extractEdidComments(content);
    final portByProfile = _extractPortComments(content);
    final wsByProfile = _extractWorkspaceComments(content);
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
      final ranks = rankByProfile[header] ?? const <String, int>{};
      final mirrors = mirrorByProfile[header] ?? const <String, String>{};
      final edids = edidByProfile[header] ?? const <String, String>{};
      final ports = portByProfile[header] ?? const <String, String>{};
      final ws = wsByProfile[header];
      profiles.add(Profile(
        name: header,
        workspaceMap: ws == null || ws.isEmpty ? null : ws,
        monitors: _applyEdids(
          _applyRanks(
            // Mirror annotations override the legacy `exec wl-mirror`
            // parsing — when both are present we trust the annotation,
            // since older GUI versions wrote both and the annotation is
            // canonical now.
            _applyMirrors(
              _applyMirrorExecs(
                  _parseOutputs(blockText, ports), blockText),
              mirrors,
            ),
            ranks,
          ),
          edids,
        ),
      ));
      i = j + 1;
    }

    return profiles;
  }

  /// Applies `# kanshi_gui:mirror '<dst>'='<src>'` annotations to the
  /// destination tile's `mirrorOf` field. Preferred over scraping
  /// `exec wl-mirror …` lines because the annotation is the canonical
  /// persistence form (no exec hook → no kanshi-spawned wl-mirror
  /// duplicate).
  static List<MonitorTileData> _applyMirrors(
    List<MonitorTileData> outputs,
    Map<String, String> mirrors,
  ) {
    if (mirrors.isEmpty) return outputs;
    return [
      for (final o in outputs)
        mirrors.containsKey(o.id) ? o.copyWith(mirrorOf: mirrors[o.id]) : o,
    ];
  }

  /// Applies `# kanshi_gui:edid '<id>'='<manufacturer>'` annotations to
  /// the matching tile's `manufacturer` field. The fallback in
  /// `_parseOutputs` sets `manufacturer = id` (we have no other signal
  /// from the kanshi DSL), so the EDID annotation is the only path that
  /// preserves real manufacturer/model/serial info across a save/load
  /// cycle. Auto-switch and the suggestion scorer both rely on this
  /// to match a profile to a physical device after the device moves
  /// between ports.
  static List<MonitorTileData> _applyEdids(
    List<MonitorTileData> outputs,
    Map<String, String> edids,
  ) {
    if (edids.isEmpty) return outputs;
    return [
      for (final o in outputs)
        edids.containsKey(o.id) && edids[o.id]!.isNotEmpty
            ? o.copyWith(manufacturer: edids[o.id])
            : o,
    ];
  }

  /// Applies the per-profile rank map captured before comment-stripping.
  static List<MonitorTileData> _applyRanks(
    List<MonitorTileData> outputs,
    Map<String, int> ranks,
  ) {
    if (ranks.isEmpty) return outputs;
    return [
      for (final o in outputs)
        ranks.containsKey(o.id) ? o.copyWith(workspaceRank: ranks[o.id]) : o,
    ];
  }

  /// Walks the raw config text and pulls
  /// `# kanshi_gui:mirror '<dst>'='<src>'` annotations out of each
  /// profile body. Returned map is profile-name → dst-id → src-id.
  static Map<String, Map<String, String>> _extractMirrorComments(
    String content,
  ) {
    final out = <String, Map<String, String>>{};
    final mirrorLine = RegExp(
      r"^\s*#\s*kanshi_gui:mirror\s+'([^']+)'\s*=\s*'([^']+)'\s*$",
    );
    String? currentProfile;
    var depth = 0;
    for (final raw in content.split('\n')) {
      if (currentProfile == null) {
        final hdr = _matchProfileHeader(raw.trim());
        if (hdr != null) {
          currentProfile = hdr;
          depth = _countChar(raw, '{') - _countChar(raw, '}');
          if (depth == 0 && raw.contains('{')) currentProfile = null;
          continue;
        }
      } else {
        final m = mirrorLine.firstMatch(raw);
        if (m != null) {
          (out[currentProfile] ??= <String, String>{})[m.group(1)!] =
              m.group(2)!;
        }
        depth += _countChar(raw, '{') - _countChar(raw, '}');
        if (depth <= 0) {
          currentProfile = null;
          depth = 0;
        }
      }
    }
    return out;
  }

  /// Walks the raw config text and pulls
  /// `# kanshi_gui:ws '<number>'='<output>'` annotations out of each profile.
  ///
  /// This is where a setup's observed workspace layout lives. It is written
  /// as a comment because kanshi has no field for it: the placement itself is
  /// carried out by the `exec swaymsg` chain, and this records what that
  /// chain should say next time.
  static Map<String, Map<int, String>> _extractWorkspaceComments(
    String content,
  ) {
    final out = <String, Map<int, String>>{};
    final wsLine = RegExp(
      r"^\s*#\s*kanshi_gui:ws\s+'(\d+)'\s*=\s*'([^']*)'\s*$",
    );
    String? currentProfile;
    var depth = 0;
    for (final raw in content.split('\n')) {
      if (currentProfile == null) {
        final hdr = _matchProfileHeader(raw.trim());
        if (hdr != null) {
          currentProfile = hdr;
          depth = _countChar(raw, '{') - _countChar(raw, '}');
          if (depth == 0 && raw.contains('{')) currentProfile = null;
          continue;
        }
      } else {
        final m = wsLine.firstMatch(raw);
        if (m != null) {
          final n = int.tryParse(m.group(1)!);
          if (n != null) {
            (out[currentProfile] ??= <int, String>{})[n] = m.group(2)!;
          }
        }
        depth += _countChar(raw, '{') - _countChar(raw, '}');
        if (depth <= 0) {
          currentProfile = null;
          depth = 0;
        }
      }
    }
    return out;
  }

  /// Walks the raw config text and pulls
  /// `# kanshi_gui:port '<descriptor>'='<connector>'` annotations out of
  /// each profile body. Returned map is profile-name → EDID descriptor →
  /// connector name.
  ///
  /// The writer emits these whenever it addresses an output by its stable
  /// EDID description, which is the whole point of M3: kanshi matches on
  /// something that survives a reboot and a redock, while the GUI still gets
  /// to know which port that was last time. A stale entry costs nothing —
  /// rehydration against the live output set corrects the connector anyway.
  static Map<String, Map<String, String>> _extractPortComments(
    String content,
  ) {
    final out = <String, Map<String, String>>{};
    final portLine = RegExp(
      r"^\s*#\s*kanshi_gui:port\s+'((?:[^'\\]|\\')*)'\s*=\s*'([^']*)'\s*$",
    );
    String? currentProfile;
    var depth = 0;
    for (final raw in content.split('\n')) {
      if (currentProfile == null) {
        final hdr = _matchProfileHeader(raw.trim());
        if (hdr != null) {
          currentProfile = hdr;
          depth = _countChar(raw, '{') - _countChar(raw, '}');
          if (depth == 0 && raw.contains('{')) currentProfile = null;
          continue;
        }
      } else {
        final m = portLine.firstMatch(raw);
        if (m != null) {
          (out[currentProfile] ??= <String, String>{})[
              m.group(1)!.replaceAll(r"\'", "'")] = m.group(2)!;
        }
        depth += _countChar(raw, '{') - _countChar(raw, '}');
        if (depth <= 0) {
          currentProfile = null;
          depth = 0;
        }
      }
    }
    return out;
  }

  /// Walks the raw config text and pulls
  /// `# kanshi_gui:edid '<id>'='<manufacturer>'` annotations out of
  /// each profile body. Returned map is profile-name → output-id →
  /// manufacturer string.
  static Map<String, Map<String, String>> _extractEdidComments(
    String content,
  ) {
    final out = <String, Map<String, String>>{};
    // Value group accepts either non-quote-non-backslash characters
    // OR an escaped apostrophe (`\'`). The writer escapes apostrophes
    // before emit; we unescape after match so the in-memory
    // `manufacturer` string is identical to what the live backend
    // produced. Configs written by 1.5.0-pre-fix never contained
    // apostrophes (the writer stripped them) so the new pattern
    // matches them trivially via the zero-or-more clause.
    final edidLine = RegExp(
      r"^\s*#\s*kanshi_gui:edid\s+'([^']+)'\s*=\s*'((?:[^'\\]|\\')*)'\s*$",
    );
    String? currentProfile;
    var depth = 0;
    for (final raw in content.split('\n')) {
      if (currentProfile == null) {
        final hdr = _matchProfileHeader(raw.trim());
        if (hdr != null) {
          currentProfile = hdr;
          depth = _countChar(raw, '{') - _countChar(raw, '}');
          if (depth == 0 && raw.contains('{')) currentProfile = null;
          continue;
        }
      } else {
        final m = edidLine.firstMatch(raw);
        if (m != null) {
          (out[currentProfile] ??= <String, String>{})[m.group(1)!] =
              m.group(2)!.replaceAll(r"\'", "'");
        }
        depth += _countChar(raw, '{') - _countChar(raw, '}');
        if (depth <= 0) {
          currentProfile = null;
          depth = 0;
        }
      }
    }
    return out;
  }

  /// Walks the raw config text and pulls `# kanshi_gui:rank '<id>'=<n>`
  /// annotations out of each profile body. Returns a map
  /// profile-name → output-id → rank.
  static Map<String, Map<String, int>> _extractRankComments(String content) {
    final out = <String, Map<String, int>>{};
    final rankLine = RegExp(
      r"^\s*#\s*kanshi_gui:rank\s+'([^']+)'\s*=\s*(\d+)\s*$",
    );
    String? currentProfile;
    var depth = 0;
    for (final raw in content.split('\n')) {
      final line = raw;
      // Detect profile header on this line (with or without inline brace).
      if (currentProfile == null) {
        final hdr = _matchProfileHeader(line.trim());
        if (hdr != null) {
          currentProfile = hdr;
          depth = _countChar(line, '{') - _countChar(line, '}');
          if (depth == 0 && line.contains('{')) {
            // Single-line `profile X {}` — close immediately.
            currentProfile = null;
          }
          continue;
        }
      } else {
        final m = rankLine.firstMatch(line);
        if (m != null) {
          final id = m.group(1)!;
          final r = int.tryParse(m.group(2)!);
          if (r != null) {
            (out[currentProfile] ??= <String, int>{})[id] = r;
          }
        }
        depth += _countChar(line, '{') - _countChar(line, '}');
        if (depth <= 0) {
          currentProfile = null;
          depth = 0;
        }
      }
    }
    return out;
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
      if (!lower.startsWith('exec')) continue;
      // The launcher form: `exec kanshi-gui-mirror DST SRC [SCALING]`.
      final launcherIdx = lower.indexOf('kanshi-gui-mirror');
      if (launcherIdx >= 0) {
        // The writer double-quotes the names (scfg strips those before
        // kanshi sees them); the tokenizer only knows single quotes.
        final args = _tokenizeShell(
                line.substring(launcherIdx + 'kanshi-gui-mirror'.length).trim())
            .map((t) => t.length >= 2 && t.startsWith('"') && t.endsWith('"')
                ? t.substring(1, t.length - 1)
                : t)
            .toList();
        if (args.length >= 2) {
          final tile = byId[args[0]];
          if (tile != null) {
            byId[args[0]] = tile.copyWith(mirrorOf: args[1]);
            dirty = true;
          }
        }
        continue;
      }
      if (!lower.contains('wl-mirror')) continue;
      // Skip the guarded exec form the writer emits today: it embeds
      // the substring `wl-mirror` inside a `pgrep -f "wl-mirror …"`
      // pattern, which this tokenising scraper would otherwise misread
      // as the actual mirror invocation. The `# kanshi_gui:mirror`
      // annotation is the canonical persistence form anyway, and
      // `_applyMirrors` runs after this pass to apply it.
      if (lower.contains('pgrep')) continue;
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
    // `(?:[^'\\]|\\.)*` so an escaped apostrophe does not terminate the
    // name — the inverse of [KanshiConfigWriter.escapeProfileName].
    final quoted =
        RegExp(r"^profile\s+'((?:[^'\\]|\\.)*)'\s*\{?\s*$").firstMatch(line);
    if (quoted != null) return _unescapeProfileName(quoted.group(1)!).trim();
    final bare = RegExp(r'^profile\s+([^\s{]+)\s*\{?\s*$').firstMatch(line);
    if (bare != null) return bare.group(1)!.trim();
    return null;
  }

  /// Inverse of [KanshiConfigWriter.escapeProfileName]: turns `\'` back into
  /// `'` and `\\` back into `\`. A backslash before anything else is kept
  /// verbatim, so a hand-written name is never mangled by this.
  static String _unescapeProfileName(String raw) {
    if (!raw.contains(r'\')) return raw;
    final out = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (ch == r'\' && i + 1 < raw.length) {
        final next = raw[i + 1];
        if (next == r'\' || next == "'") {
          out.write(next);
          i++;
          continue;
        }
      }
      out.write(ch);
    }
    return out.toString();
  }

  static List<MonitorTileData> _parseOutputs(
    String block, [
    Map<String, String> portByDescriptor = const {},
  ]) {
    final outputs = <MonitorTileData>[];
    // Three criteria spellings: 'single-quoted' (what this app has always
    // written for connectors), "double-quoted" (kanshi(5)'s documented form,
    // and what a stable EDID description needs because it contains spaces),
    // and bare.
    // Anchored at the start of a line. Without the anchor the pattern also
    // matched INSIDE `...output "X" enable`, so the ellipsis form — which
    // this app cannot express — was read as an ordinary output and written
    // back as a second, duplicate directive next to the original.
    final outputRE = RegExp(
      "^[ \\t]*output\\s+(?:'([^']+)'|\"([^\"]+)\"|(\\S+))"
      r"\s+(enable|disable)([^\n]*)",
      caseSensitive: false,
      multiLine: true,
    );

    for (final m in outputRE.allMatches(block)) {
      final quoted = m.group(1);
      final doubleQuoted = m.group(2);
      final criteria = (quoted ?? doubleQuoted ?? m.group(3) ?? '').trim();
      if (criteria.isEmpty) continue;
      final state = m.group(4)!.toLowerCase();
      final rest = m.group(5) ?? '';
      final isEnabled = state == 'enable';

      // A criteria containing spaces is an EDID description, not a
      // connector. Keep it as the stable identity and resolve the connector
      // through the `# kanshi_gui:port` annotation when one was recorded —
      // a stale annotation is harmless, since rehydration against the live
      // output set corrects the id anyway.
      final looksLikeDescriptor =
          doubleQuoted != null || criteria.contains(' ');
      final descriptor = looksLikeDescriptor ? criteria : '';
      final name = looksLikeDescriptor
          ? (portByDescriptor[criteria] ?? criteria)
          : criteria;

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
        edidDescriptor: descriptor,
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
      // Both quote characters, and a quote inside the other kind is just a
      // character. Only single quotes were tracked, so a `#` inside a
      // DOUBLE-quoted output description — the form every stable EDID
      // criteria is written in — looked like the start of a comment. The
      // rest of the line was discarded, the `output` directive lost its
      // arguments, and the display quietly disappeared from the setup on the
      // next read. `Acme #1` is a perfectly ordinary thing for a monitor to
      // call itself.
      String? quote;
      var idx = 0;
      while (idx < raw.length) {
        final ch = raw[idx];
        if (quote == null && (ch == "'" || ch == '"')) {
          quote = ch;
        } else if (ch == quote) {
          quote = null;
        } else if (quote == null && ch == '#') {
          break;
        }
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
