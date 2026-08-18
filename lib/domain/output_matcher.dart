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
  ///
  /// **Two descriptors that disagree end the question.** They are proof of two
  /// different screens, and no weaker signal is allowed to argue with proof.
  ///
  /// That sentence used to be missing, and it cost a user their setup. They
  /// had a saved three-screen office, recorded down to the EDID serials of two
  /// Samsung panels. In another room they plugged into a different dock with
  /// two panels of the same model — different units, different serials — and
  /// the dock happened to hand out the same connector names, `DP-4` and
  /// `DP-5`. The descriptors disagreed, so the check above fell through, the
  /// connector names agreed, and the app declared them the same screens.
  ///
  /// Everything followed from that. The saved office was re-pointed at the
  /// room the user was actually in, and — because re-hydration writes the
  /// observed identity back — its recorded serials were overwritten with the
  /// new panels'. The setup for the other room was gone, unrecoverably, from
  /// one coincidence of port naming. The window then showed that room's saved
  /// positions over these screens' real ones, which is what the dashed drift
  /// ghosts and the off-centre canvas were: the app was describing a desk two
  /// doors away.
  ///
  /// A connector name is the one piece of evidence `kanshi(5)` explicitly
  /// warns about — "output names may not be stable: they may change across
  /// reboots \[…\] or creation order (typically for USB-C docks)". Letting it
  /// speak over a recorded EDID inverted the entire strength order this
  /// function exists to express.
  static MatchStrength? strength(
    MonitorTileData live,
    MonitorTileData entry,
  ) {
    if (live.edidDescriptor.isNotEmpty && entry.edidDescriptor.isNotEmpty) {
      return same(live.edidDescriptor, entry.edidDescriptor)
          ? MatchStrength.descriptor
          // Both sides know who they are and they are not the same display.
          // No fall-through: the weaker passes exist for entries that have no
          // descriptor to offer, not to overrule one that does.
          : null;
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
