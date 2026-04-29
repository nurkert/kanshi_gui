import 'package:kanshi_gui/models/monitor_tile_data.dart';

/// Heuristic that picks a sensible default profile name for a given live
/// output topology. Pure function — easily testable, no Flutter deps.
///
/// Examples:
///   - 1 output, eDP-* → "Laptop only"
///   - 1 eDP + 1 external → "Docked"
///   - 2 outputs, both external → "Dual external"
///   - 3+ outputs → "Triple Setup" / "Quad Setup" / "{N}-Monitor Setup"
class ProfileNamer {
  ProfileNamer._();

  static String suggest(List<MonitorTileData> outputs) {
    if (outputs.isEmpty) return 'Empty';
    final embedded =
        outputs.where(_looksEmbedded).toList(growable: false);
    final external =
        outputs.where((o) => !_looksEmbedded(o)).toList(growable: false);

    if (outputs.length == 1) {
      return embedded.length == 1 ? 'Laptop only' : 'Single display';
    }
    if (embedded.length == 1 && external.length == 1) {
      return 'Docked';
    }
    if (embedded.length == 1 && external.length >= 2) {
      return 'Docked + ${external.length} externals';
    }
    if (embedded.isEmpty && external.length == 2) {
      return 'Dual external';
    }
    if (outputs.length == 3) return 'Triple Setup';
    if (outputs.length == 4) return 'Quad Setup';
    return '${outputs.length}-Monitor Setup';
  }

  /// Best-effort detection: most laptop panels use connectors named eDP-*,
  /// LVDS-*, or DSI-*. Be permissive — this only drives the suggested name,
  /// the user can always override.
  static bool _looksEmbedded(MonitorTileData o) {
    final name = o.id.toUpperCase();
    return name.startsWith('EDP-') ||
        name.startsWith('LVDS-') ||
        name.startsWith('DSI-');
  }
}
