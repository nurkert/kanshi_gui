// Pure Dart. No Flutter, no dart:io — this is the start of the domain core
// PLAN-2.0.md describes, and it must stay importable from anywhere.

/// How an output is addressed in a kanshi config.
///
/// `kanshi(5)` is explicit about why this matters:
///
/// > An output name (e.g. "DP-1"). Note, output names may not be stable: they
/// > may change across reboots (depending on kernel driver probe order) or
/// > creation order (typically for USB-C docks).
///
/// kanshi_gui wrote the unstable form for its whole life and kept the stable
/// one in a comment only it could read, which is why a reboot or a redock
/// could leave the arrangement — and the workspaces pinned to it — wrong.
enum OutputCriteriaKind {
  /// `output 'DP-1'` — the connector. Unstable, but the only option when the
  /// display reports no usable EDID or when two displays are
  /// indistinguishable.
  connector,

  /// `output "Make Model Serial"` — the EDID description. Stable across
  /// reboots and across ports.
  description,
}

/// An output criteria plus the knowledge of which kind it is, so callers can
/// quote it correctly for the context they are writing into.
class OutputCriteria {
  final OutputCriteriaKind kind;
  final String value;

  const OutputCriteria(this.kind, this.value);

  const OutputCriteria.connector(this.value)
      : kind = OutputCriteriaKind.connector;

  const OutputCriteria.description(this.value)
      : kind = OutputCriteriaKind.description;

  bool get isDescription => kind == OutputCriteriaKind.description;

  /// Whether this criteria is safe to put into a command that a shell will
  /// run. See [isShellSafeCriteria].
  bool get isShellSafe => isShellSafeCriteria(value);

  /// Rendered for a kanshi config `output <criteria>` line.
  ///
  /// Descriptions contain spaces and go in double quotes, which is the form
  /// `kanshi(5)` documents. Connectors keep the single-quoted form the app
  /// has always written — kanshi accepts it (verified against a running
  /// daemon) and changing it would churn every existing config for nothing.
  ///
  /// Both forms escape, because this is a config file the app has to be able
  /// to read back: an unescaped `"` inside a description ends the scfg string
  /// early and the profile stops parsing.
  String get configForm => isDescription
      ? '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"'
      : "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  /// Rendered for the `output <criteria>` argument of a swaymsg command that
  /// this app emits inside a **double-quoted** `exec swaymsg "…"` string.
  ///
  /// Single quotes, for both kinds, and the reason is worth spelling out
  /// because `kanshi(5)` shows something that looks different:
  ///
  /// > exec swaymsg workspace 1, move workspace to output '"Some Other
  /// > Company GTBZ 2525"'
  ///
  /// That example has no quotes around the swaymsg argument, so two layers
  /// strip it: the shell removes `'…'` and sway then removes `"…"`. Our chain
  /// has to travel as one argument because it is `;`-separated, so it is
  /// wrapped in `exec swaymsg "…"` — and inside that, a literal `"` would end
  /// the string early and hand kanshi a mangled command. Here the shell
  /// leaves `'…'` alone and sway performs the single strip, which lands on
  /// the same value. One layer of quoting, applied once.
  ///
  /// And that is exactly why the value has to be vetted before it gets here.
  /// The single quotes sit INSIDE a double-quoted shell string, so the shell
  /// does not treat them as quoting at all — it expands `$…`, `$(…)` and
  /// backticks straight through them. A display reporting itself as
  /// `Acme $(id -un) Corp` produced
  ///
  ///     exec swaymsg "workspace 1 output 'Acme $(id -un) Corp'"
  ///
  /// and kanshi ran that through a shell on every profile apply. EDID is
  /// attacker-controlled: a hostile dock or a conference-room projector is
  /// enough. [isShellSafeCriteria] is the gate, applied in
  /// [chooseOutputCriteria] so a dangerous description never becomes criteria
  /// in the first place; the escaping here is the second line of defence for
  /// anything that reaches this method by another route.
  String get swayExecForm {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`')
        .replaceAll('"', r'\"');
    return "'$escaped'";
  }

  /// Rendered for an `exec` line in the kanshi config, which travels through
  /// scfg and then through `/bin/sh` before it reaches swaymsg.
  ///
  /// The nested form `'"…"'` is what `kanshi(5)` shows, and it took reading
  /// kanshi's parser to understand why. Three layers strip one quote each:
  /// scfg removes the single quotes when it reads the config, kanshi
  /// backslash-escapes the double quotes it finds so the shell hands them to
  /// swaymsg intact, and sway removes them last. Get it wrong in either
  /// direction and the failure is silent — sway drops an output target it
  /// cannot resolve without complaining.
  ///
  /// This app used the single-quoted form here for four releases, reasoning
  /// that "one layer of quoting, applied once" was enough. That was true of
  /// kanshi before 1.9, which read the raw line. It has not been true since.
  String get kanshiExecForm => "'\"$value\"'";

  @override
  bool operator ==(Object other) =>
      other is OutputCriteria && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'OutputCriteria.${kind.name}($value)';
}

/// Composes the `make model serial` description kanshi matches outputs by,
/// or null when the display supplies nothing usable.
///
/// `kanshi(5)`: *"If one of these fields is missing, it needs to be populated
/// with the string 'Unknown'"*. Both backends strip "Unknown" when building
/// the human-readable label — a laptop panel with no serial should not be
/// called "… Unknown" in the UI — so the label cannot be reused here. This
/// keeps the exact triple kanshi wants, separately from what we show people.
String? composeKanshiDescriptor({
  String? make,
  String? model,
  String? serial,
}) {
  // Control characters are stripped and whitespace runs collapsed before
  // anything else looks at the value. EDID is 128 bytes from a device, not a
  // trusted string: a newline in a model name broke out of the
  // `# kanshi_gui:edid …` comment the writer records the identity in and
  // became a config line of its own — including, if the device wanted one, an
  // `exec` line. Fixing it at the point of composition means every consumer
  // downstream gets a value that is at worst wrong, never structural.
  String norm(String? s) {
    final t = (s ?? '')
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t.isEmpty ? 'Unknown' : t;
  }

  final m = norm(make);
  final mo = norm(model);
  final se = norm(serial);
  // All three unknown carries no identity at all — matching on
  // "Unknown Unknown Unknown" would match any such display, which is worse
  // than falling back to the connector name.
  if (m == 'Unknown' && mo == 'Unknown' && se == 'Unknown') return null;
  return '$m $mo $se';
}

/// What an output criteria may contain before the app is willing to put it
/// into a command that a shell will run.
///
/// A whitelist, not a blacklist, and deliberately narrow, because the escaping
/// is not ours to control. `kanshi(5)` runs `exec` lines through `/bin/sh`,
/// and kanshi 1.9 re-escapes exactly five characters on the way — space, tab,
/// backslash, and the two quotes (`config.c:270-276`). Everything else arrives
/// at the shell bare and means what the shell says it means. There is no
/// quoting we can add from inside the value: kanshi escapes our quotes too, so
/// they land as literal characters rather than as quoting.
///
/// So a bracket is not an escaping problem, it is an unsolvable one. The
/// user's own laptop panel reports `InfoVision Optoelectronics (Kunshan)
/// Co.,Ltd China 0x057D Unknown`, and that bracket aborted the entire exec
/// line with `Syntax error: "(" unexpected` — every workspace binding in the
/// file, gone, silently, for as long as that display was attached.
///
/// A display that does not fit is not rejected: it is addressed by its
/// connector name instead, which the kernel guarantees is alphanumeric. The
/// stable EDID description is still what the `output` directive uses — see
/// [chooseOutputCriteria] versus [chooseExecCriteria].
bool isShellSafeCriteria(String value) =>
    value.isNotEmpty && _safeCriteria.hasMatch(value);

/// Commas are in: harmless to a shell, and `Co.,Ltd` is a real make. Brackets
/// and every other shell metacharacter are out.
final RegExp _safeCriteria = RegExp(r'^[A-Za-z0-9 ._\-+:/=%,]+$');

/// Whether this value can be written into the kanshi config as an output
/// criteria at all.
///
/// A far wider net than [isShellSafeCriteria], because scfg is a saner parser
/// than a shell: quotes and backslashes are escapable and [OutputCriteria
/// .configForm] escapes them. What is NOT escapable is a line ending. A
/// display reporting `Acme\n    exec touch /tmp/x` would end the `output` line
/// and leave the rest standing as a directive of its own — a way to write an
/// `exec` into someone's config by handing them a monitor.
///
/// [composeKanshiDescriptor] already strips control characters at the point
/// EDID enters the app; this is the backstop for a value that arrived some
/// other way.
bool isConfigSafeCriteria(String value) =>
    value.isNotEmpty && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

/// Makes [value] safe to appear in a kanshi `exec` line, by removing what
/// cannot be made safe.
///
/// Quoting does not work here, and it is worth being precise about why,
/// because two attempts at it failed before this. A kanshi config line is read
/// by scfg first, which CONSUMES the quotes we write; kanshi then re-escapes
/// only whitespace, backslash and the two quote characters before handing the
/// result to `/bin/sh`. So `'…'` around a value disappears at the scfg layer
/// and never reaches the shell as quoting — a `$(…)` inside it is expanded
/// exactly as if we had written nothing. There is no sequence we can emit that
/// makes a `$` or a backtick literal.
///
/// What is left is to not write them. Unsafe runs collapse to a single space;
/// an empty result means the caller should omit the line entirely. This only
/// affects a display name or a setup name someone chose to spell with shell
/// syntax in it, and only in the one place that goes through a shell — the
/// name is stored, shown and matched on in full everywhere else.
String shellSafeText(String value) => value
    .replaceAll(RegExp(r'[^A-Za-z0-9 ._\-+:/=%,]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Chooses how each output in a profile should be addressed.
///
/// Descriptions win wherever they exist and are unique. Where two displays in
/// the same profile share a descriptor — same model, blank or identical
/// serial — kanshi genuinely cannot tell them apart, so *that pair* falls
/// back to connector names while the rest of the profile stays stable.
///
/// [descriptorOf] returns the EDID descriptor for a connector, or null.
Map<String, OutputCriteria> chooseOutputCriteria(
  Iterable<String> connectors,
  String? Function(String connector) descriptorOf,
) {
  final byDescriptor = <String, List<String>>{};
  for (final c in connectors) {
    final d = descriptorOf(c);
    if (d == null || d.isEmpty) continue;
    (byDescriptor[d] ??= <String>[]).add(c);
  }

  final result = <String, OutputCriteria>{};
  for (final c in connectors) {
    final d = descriptorOf(c);
    final unique = d != null &&
        d.isNotEmpty &&
        byDescriptor[d]!.length == 1 &&
        isConfigSafeCriteria(d);
    result[c] = unique
        ? OutputCriteria.description(d)
        : OutputCriteria.connector(c);
  }
  return result;
}

/// The same choice, narrowed to what may go into a command a shell will run.
///
/// Two contexts, two answers, and conflating them breaks one or the other.
/// The `output "…"` directive in the config is read by kanshi's own parser and
/// is how a profile is recognised at all, so it must keep the stable EDID
/// description whatever characters it contains — [configForm] escapes what
/// that parser needs. An `exec` line is handed to `/bin/sh`, where the same
/// description can be a syntax error, and there the connector name is the
/// only thing that can be relied on.
///
/// So: recognise the desk by its displays, address the displays by their ports
/// when telling a shell about them.
Map<String, OutputCriteria> chooseExecCriteria(
  Iterable<String> connectors,
  String? Function(String connector) descriptorOf,
) {
  final base = chooseOutputCriteria(connectors, descriptorOf);
  return {
    for (final entry in base.entries)
      entry.key: entry.value.isShellSafe
          ? entry.value
          : OutputCriteria.connector(entry.key),
  };
}
