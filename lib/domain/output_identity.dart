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

  /// Rendered for a kanshi config `output <criteria>` line.
  ///
  /// Descriptions contain spaces and go in double quotes, which is the form
  /// `kanshi(5)` documents. Connectors keep the single-quoted form the app
  /// has always written — kanshi accepts it (verified against a running
  /// daemon) and changing it would churn every existing config for nothing.
  String get configForm =>
      isDescription ? '"$value"' : "'${value.replaceAll("'", r"\'")}'";

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
  String get swayExecForm => "'$value'";

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
  String norm(String? s) {
    final t = (s ?? '').trim();
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
    final unique = d != null && d.isNotEmpty && byDescriptor[d]!.length == 1;
    result[c] = unique
        ? OutputCriteria.description(d)
        : OutputCriteria.connector(c);
  }
  return result;
}
