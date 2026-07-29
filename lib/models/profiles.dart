// lib/models/profiles.dart

import 'monitor_tile_data.dart';

/// One remembered setup: a set of screens and how they are arranged.
class Profile {
  String name;
  List<MonitorTileData> monitors;

  /// Where the numbered sway workspaces live, learned from the running
  /// compositor rather than configured.
  ///
  /// Maps workspace number to output id. Null when this setup has never been
  /// observed, in which case the distribution rule is used to seed one.
  ///
  /// Learned rather than chosen because "interleaved or grouped?" is a
  /// question the user cannot answer without trying both: they know where
  /// they want their workspaces, and they express that by putting them
  /// there. The app's job is to notice and put them back.
  Map<int, String>? workspaceMap;

  Profile({
    required this.name,
    required this.monitors,
    this.workspaceMap,
  });
}
