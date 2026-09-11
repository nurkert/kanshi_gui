import 'dart:math';

import 'package:kanshi_gui/models/monitor_tile_data.dart';

/// Where a mirror destination goes, and which screen should be the source.
///
/// Flutter-free on purpose: the config writer needs this, and so may the
/// workspace helper one day, and neither may drag `dart:ui` in.
class MirrorGeometry {
  MirrorGeometry._();

  /// Logical pixels between the independent screens and a mirror
  /// destination.
  ///
  /// A mirror destination shows someone else's picture, so the pointer has no
  /// business there: a click lands on wl-mirror's window, focus goes with it,
  /// and the next keystroke or `$mod+Return` disappears behind a fullscreen
  /// surface on a screen the user is not looking at. Placing the destination
  /// flush against the source — the only thing earlier releases did about the
  /// pointer — is exactly what lets it wander over.
  ///
  /// wlroots moves the pointer to the point of the output layout closest to
  /// where the motion wanted to go (`wlr_cursor_move` →
  /// `wlr_cursor_warp_closest` → `wlr_output_layout_closest_point`,
  /// wlroots 0.20 `types/wlr_cursor.c`). Across a gap that is the edge of the
  /// screen the pointer is on, unless a single motion event carries it more
  /// than half the gap. Two thousand logical pixels is beyond any mouse or
  /// touchpad event, and still small enough that a whole-layout screenshot
  /// stays a sane size.
  static const double pointerGap = 2000;

  /// The workspace a mirror destination shows its copy on: `⇄ DP-5` for a
  /// screen showing DP-5.
  ///
  /// Named, not numbered, on purpose. wl-mirror's window lands on whatever
  /// workspace the destination happens to have, and sway numbers a fresh one
  /// with the lowest free digit — which the workspace rule then assigns to
  /// another screen. The helper's next repair walk moved workspace 4 to the
  /// laptop, with the mirror inside it, and the destination was left showing
  /// an empty "10". Repairs and bindings only ever touch 1..9; a workspace
  /// with a name of its own is outside everything that moves numbers.
  static String workspaceName(String sourceId) => '$_workspaceMark $sourceId';

  /// Whether [workspaceName] is one of ours.
  static bool isMirrorWorkspace(String workspaceName) =>
      workspaceName.startsWith('$_workspaceMark ');

  static const String _workspaceMark = '⇄';

  /// Whether [id] names a built-in panel (`eDP-1`, `LVDS-1`, `DSI-1`, …).
  ///
  /// Connector names come from the kernel and follow the DRM connector type
  /// names; everything that is not one of these is an external port.
  static bool isInternalPanel(String id) {
    final upper = id.toUpperCase();
    return upper.startsWith('EDP-') ||
        upper.startsWith('LVDS-') ||
        upper.startsWith('DSI-');
  }

  /// The screen the others should copy when the user asks to "mirror".
  ///
  /// The built-in panel if there is one: someone who mirrors a laptop onto a
  /// projector wants the projector to show the laptop, and never the other
  /// way round. Without a built-in panel the leftmost screen, which is the
  /// convention the layout presets already use for "primary".
  ///
  /// Returns null when [candidates] is empty.
  static MonitorTileData? preferredSource(Iterable<MonitorTileData> candidates) {
    final list = candidates.toList(growable: false);
    if (list.isEmpty) return null;
    for (final m in list) {
      if (isInternalPanel(m.id)) return m;
    }
    list.sort((a, b) {
      final byX = a.x.compareTo(b.x);
      return byX != 0 ? byX : a.id.compareTo(b.id);
    });
    return list.first;
  }

  /// The position a mirror destination is applied at: to the right of the
  /// independent screens, [pointerGap] away.
  ///
  /// [cluster] is every enabled screen that is not a mirror destination.
  /// Destinations are stacked in a lane so two of them never overlap, in
  /// order of [destinations]. Positions are logical, like the tiles' own.
  static ({double x, double y}) detachedPosition(
    MonitorTileData destination, {
    required Iterable<MonitorTileData> cluster,
    required Iterable<MonitorTileData> destinations,
    double gap = pointerGap,
  }) {
    final anchors = cluster.toList(growable: false);
    if (anchors.isEmpty) return (x: destination.x, y: destination.y);
    final clusterRight = anchors.map((m) => m.x + _spanX(m)).reduce(max);
    final clusterTop = anchors.map((m) => m.y).reduce(min);
    var y = clusterTop;
    for (final d in destinations) {
      if (d.id == destination.id) break;
      y += _spanY(d) + gap;
    }
    return (x: clusterRight + gap, y: y);
  }

  /// [detachedPosition] applied to every mirror destination in [monitors];
  /// the other tiles pass through unchanged.
  static List<MonitorTileData> withDetachedDestinations(
    List<MonitorTileData> monitors, {
    double gap = pointerGap,
  }) {
    final cluster = monitors
        .where((m) => m.enabled && m.mirrorOf == null)
        .toList(growable: false);
    final destinations = monitors
        .where((m) => m.enabled && m.mirrorOf != null)
        .toList(growable: false);
    if (destinations.isEmpty) return monitors;
    return [
      for (final m in monitors)
        if (m.enabled && m.mirrorOf != null)
          _moved(
            m,
            detachedPosition(
              m,
              cluster: cluster,
              destinations: destinations,
              gap: gap,
            ),
          )
        else
          m,
    ];
  }

  /// Where a released destination goes back to.
  ///
  /// The model normally still holds the position the screen had before it
  /// became a copy, and that is kept. But a config reload may have read the
  /// detached position back in; a screen that far from the others is put
  /// flush against their right edge, so it is a screen the pointer can reach
  /// and the canvas shows it next to the rest rather than a gap away.
  static MonitorTileData rejoined(
    MonitorTileData released,
    Iterable<MonitorTileData> cluster,
  ) {
    final anchors =
        cluster.where((m) => m.id != released.id).toList(growable: false);
    if (anchors.isEmpty) return released;
    final left = anchors.map((m) => m.x).reduce(min);
    final top = anchors.map((m) => m.y).reduce(min);
    final right = anchors.map((m) => m.x + _spanX(m)).reduce(max);
    final bottom = anchors.map((m) => m.y + _spanY(m)).reduce(max);
    final dx = max(0.0, max(left - (released.x + _spanX(released)),
        released.x - right));
    final dy = max(0.0, max(top - (released.y + _spanY(released)),
        released.y - bottom));
    if (dx < pointerGap / 2 && dy < pointerGap / 2) return released;
    return released.copyWith(x: right, y: top);
  }

  static MonitorTileData _moved(
    MonitorTileData m,
    ({double x, double y}) at,
  ) =>
      m.copyWith(x: at.x, y: at.y);

  static double _spanX(MonitorTileData m) =>
      m.scale > 0 ? m.width / m.scale : m.width;

  static double _spanY(MonitorTileData m) =>
      m.scale > 0 ? m.height / m.scale : m.height;
}
