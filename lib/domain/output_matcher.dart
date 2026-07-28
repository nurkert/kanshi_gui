// Pure Dart. No Flutter, no dart:io.

import 'package:kanshi_gui/models/monitor_tile_data.dart';

/// Deciding whether two references name the same physical screen.
///
/// This is the single most load-bearing question the app asks, and it was
/// scattered across the controller as a handful of private helpers. It is
/// also pure: it depends on nothing but the two values, which makes it
/// exactly the kind of thing that belongs in a domain module with tests of
/// its own rather than inside a 2,800-line ChangeNotifier.
class OutputMatcher {
  OutputMatcher._();

  /// Collapses whitespace runs, trims and lowercases.
  ///
  /// EDID strings come from hardware and are not tidy — doubled spaces and
  /// trailing blanks are common — and connector names differ in case between
  /// tools. Comparing raw strings loses matches for reasons that have nothing
  /// to do with the hardware.
  static String normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  /// Whether two identity strings refer to the same output.
  static bool same(String a, String b) => normalize(a) == normalize(b);

  /// Whether [live] and [entry] are the same screen, and on what evidence.
  ///
  /// Strength order matters and is the reason a profile survives a reboot:
  /// the EDID descriptor is stable across reboots and ports, the connector
  /// name is not, and the display label is only a fallback for entries that
  /// predate descriptors being recorded.
  static MatchStrength? strength(
    MonitorTileData live,
    MonitorTileData entry,
  ) {
    if (live.edidDescriptor.isNotEmpty &&
        entry.edidDescriptor.isNotEmpty &&
        same(live.edidDescriptor, entry.edidDescriptor)) {
      return MatchStrength.descriptor;
    }
    if (entry.id.isNotEmpty && same(live.id, entry.id)) {
      return MatchStrength.connector;
    }
    if (entry.manufacturer.isNotEmpty &&
        same(live.manufacturer, entry.manufacturer)) {
      return MatchStrength.label;
    }
    return null;
  }

  /// Resolves [reference] — a connector name, an EDID descriptor or a display
  /// label — to the connector name a live output currently has.
  ///
  /// Returns [reference] unchanged when nothing matches, so callers that pass
  /// it to a compositor still produce a comprehensible error rather than an
  /// empty argument.
  static String resolveConnector(
    String reference,
    Iterable<MonitorTileData> live,
  ) {
    final norm = normalize(reference);
    for (final m in live) {
      if (normalize(m.id) == norm ||
          normalize(m.manufacturer) == norm ||
          (m.edidDescriptor.isNotEmpty &&
              normalize(m.edidDescriptor) == norm)) {
        return m.id;
      }
    }
    return reference;
  }

  /// Pairs profile entries with live outputs, strongest evidence first.
  ///
  /// Each pass only sees entries no earlier pass matched and live outputs no
  /// earlier pass claimed, so a weaker signal can never steal a display from
  /// a stronger one. Without that rule a profile holding two identical
  /// monitors re-hydrates both from whichever live output comes first, and
  /// the two physical screens silently swap mode lists.
  ///
  /// Returns entry-index → live-index.
  static Map<int, int> pair(
    List<MonitorTileData> entries,
    List<MonitorTileData> live,
  ) {
    final result = <int, int>{};
    final claimedLive = <int>{};
    for (final level in MatchStrength.values) {
      for (var i = 0; i < entries.length; i++) {
        if (result.containsKey(i)) continue;
        for (var j = 0; j < live.length; j++) {
          if (claimedLive.contains(j)) continue;
          if (strength(live[j], entries[i]) != level) continue;
          result[i] = j;
          claimedLive.add(j);
          break;
        }
      }
    }
    return result;
  }
}

/// How much a match can be trusted, strongest first.
enum MatchStrength {
  /// Same EDID make/model/serial. Survives reboots and port changes.
  descriptor,

  /// Same connector name. `kanshi(5)` warns these change across reboots and
  /// on USB-C docks.
  connector,

  /// Same display label. A fallback for profiles written before descriptors
  /// were recorded; two identical panels share one.
  label,
}
