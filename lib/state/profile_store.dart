import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// The saved setups and which one is currently in play.
///
/// The controller reads this in about eighty places, which is fine — it is
/// the app's subject matter. What was not fine is that it also *wrote* it in
/// twenty, each with its own idea of how to replace a monitor inside a
/// profile: some assigned into the existing list, some rebuilt the Profile,
/// some captured the list first and wrote into it after an await. That last
/// shape is what let safety-net reverts write into an orphaned list while
/// the compositor and the config drifted apart.
///
/// So the store deliberately exposes no way to reach a mutable list. Every
/// change goes through a named method, and each one leaves the profile in a
/// consistent state before it returns.
class ProfileStore {
  final List<Profile> _profiles = [];
  int? _activeIndex;

  /// Read-only view. Callers that want to change something use the methods
  /// below rather than mutating what they get back.
  List<Profile> get profiles => List.unmodifiable(_profiles);

  int get length => _profiles.length;
  bool get isEmpty => _profiles.isEmpty;

  int? get activeIndex => _activeIndex;

  Profile? get active =>
      _activeIndex == null ? null : _profiles[_activeIndex!];

  /// The active setup's monitors, or an empty list when nothing is active.
  List<MonitorTileData> get activeMonitors =>
      active?.monitors ?? const <MonitorTileData>[];

  /// Replaces everything, e.g. after loading the config or restoring a
  /// history snapshot. Copies, so the caller's list stays theirs.
  void replaceAll(List<Profile> next, {int? activeIndex}) {
    _profiles
      ..clear()
      ..addAll([
        for (final p in next)
          Profile(
            name: p.name,
            monitors: [...p.monitors],
            workspaceMap:
                p.workspaceMap == null ? null : Map.of(p.workspaceMap!),
          ),
      ]);
    _activeIndex = _clamp(activeIndex);
  }

  set activeIndex(int? index) => _activeIndex = _clamp(index);

  int indexOfName(String name) => _profiles.indexWhere((p) => p.name == name);

  bool nameTaken(String name, {int? excludingIndex}) {
    final lower = name.toLowerCase();
    for (var i = 0; i < _profiles.length; i++) {
      if (i == excludingIndex) continue;
      if (_profiles[i].name.toLowerCase() == lower) return true;
    }
    return false;
  }

  void add(Profile profile, {bool makeActive = false}) {
    _profiles.add(profile);
    if (makeActive) _activeIndex = _profiles.length - 1;
  }

  /// Removes [index] and keeps the active pointer meaningful.
  ///
  /// Deleting the active setup leaves nothing active rather than silently
  /// selecting a neighbour — the user removed the thing they were editing,
  /// and quietly moving them into a different one would be a surprise. A
  /// deletion *before* the active one shifts the index down so it still names
  /// the same Profile.
  void removeAt(int index) {
    if (index < 0 || index >= _profiles.length) return;
    final wasActive = _activeIndex;
    _profiles.removeAt(index);
    if (wasActive == null) return;
    if (wasActive == index) {
      _activeIndex = null;
    } else if (wasActive > index) {
      _activeIndex = wasActive - 1;
    }
  }

  void rename(int index, String name) {
    if (index < 0 || index >= _profiles.length) return;
    _profiles[index].name = name;
  }

  /// Replaces the monitor list of [index] wholesale.
  void setMonitors(int index, List<MonitorTileData> monitors) {
    if (index < 0 || index >= _profiles.length) return;
    _profiles[index] = Profile(
      name: _profiles[index].name,
      monitors: [...monitors],
      workspaceMap: _profiles[index].workspaceMap,
    );
  }

  /// Applies [update] to the monitor [outputId] inside the profile named
  /// [profileName], resolving both at call time. Returns false when either is
  /// gone.
  ///
  /// This is the shape deferred work must use. Anything that resumes after an
  /// await — a safety-net revert above all — must not have captured a list:
  /// nearly every mutation replaces the Profile object, so the captured list
  /// becomes an orphan that nothing reads, and the compositor and the saved
  /// config disagree from then on. Nor may it just use whatever is active
  /// when it resumes, because the user may have switched in the meantime.
  bool updateMonitorIn(
    String profileName,
    String outputId,
    MonitorTileData Function(MonitorTileData) update,
  ) {
    final pIdx = indexOfName(profileName);
    if (pIdx == -1) return false;
    final mons = [..._profiles[pIdx].monitors];
    final i = mons.indexWhere((m) => m.id == outputId);
    if (i == -1) return false;
    mons[i] = update(mons[i]);
    _profiles[pIdx] = Profile(
      name: _profiles[pIdx].name,
      monitors: mons,
      workspaceMap: _profiles[pIdx].workspaceMap,
    );
    return true;
  }

  /// The monitor [outputId] inside the profile named [profileName], or null.
  MonitorTileData? monitorIn(String profileName, String outputId) {
    final pIdx = indexOfName(profileName);
    if (pIdx == -1) return null;
    final i = _profiles[pIdx].monitors.indexWhere((m) => m.id == outputId);
    return i == -1 ? null : _profiles[pIdx].monitors[i];
  }

  /// Applies [update] to one monitor of the ACTIVE profile. Returns false when
  /// nothing is active or the output is not in it.
  bool updateActiveMonitor(
    String outputId,
    MonitorTileData Function(MonitorTileData) update,
  ) {
    final idx = _activeIndex;
    if (idx == null) return false;
    final mons = [..._profiles[idx].monitors];
    final i = mons.indexWhere((m) => m.id == outputId);
    if (i == -1) return false;
    mons[i] = update(mons[i]);
    _profiles[idx] = Profile(
      name: _profiles[idx].name,
      monitors: mons,
      workspaceMap: _profiles[idx].workspaceMap,
    );
    return true;
  }

  /// Rewrites every monitor of the active profile through [update].
  bool mapActiveMonitors(
    MonitorTileData Function(MonitorTileData) update,
  ) {
    final idx = _activeIndex;
    if (idx == null) return false;
    setMonitors(idx, _profiles[idx].monitors.map(update).toList());
    return true;
  }

  int? _clamp(int? index) {
    if (index == null) return null;
    if (index < 0 || index >= _profiles.length) return null;
    return index;
  }
}
