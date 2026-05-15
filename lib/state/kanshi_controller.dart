import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/process_runner.dart';
import 'package:kanshi_gui/state/custom_mode_revert_scheduler.dart';
import 'package:kanshi_gui/state/safety_net.dart';

/// Lightweight result type returned by mutating controller operations so the
/// UI can decide whether to show a snackbar. Avoids leaking [ProcessResult]
/// or stack traces into the widget tree.
class OpResult {
  final bool success;
  final String? message;
  const OpResult.ok([this.message]) : success = true;
  const OpResult.err(this.message) : success = false;
}

/// Holds the live application state (profiles, currently connected outputs,
/// active profile) and orchestrates compositor + config-file mutations.
/// All UI state changes happen through this controller; widgets observe via
/// [ListenableBuilder] / [AnimatedBuilder].
class KanshiController extends ChangeNotifier {
  final MonitorService monitors;
  final ConfigService config;
  final MirrorRunner mirrorRunner;
  final CustomModeRevertScheduler _revertScheduler =
      CustomModeRevertScheduler();
  final SafetyNet safetyNet = SafetyNet();

  /// Snap distance used by the layout helpers, in *logical* (sway-coord)
  /// pixels — same units as `MonitorTileData.x/y`. Public so widgets
  /// that need to mirror the value (e.g. for cursor hints) can read
  /// it.
  ///
  /// 60 was chosen as a balance: it's small enough that an intentional
  /// ~100 px gap between two monitors stays free (no surprise snap
  /// pulling the user to alignment), yet generous enough that "near
  /// flush against the neighbour" reliably engages. The historical
  /// default was 500, which was effectively "always snap" because for
  /// a 1920-wide monitor 500 px is more than a quarter of the screen.
  final double snapThreshold;

  List<Profile> _profiles = [];
  List<MonitorTileData> _currentMonitors = [];
  int? _activeProfileIndex;
  bool _isApplyingBatch = false;
  Timer? _saveTimer;
  /// Serialises [_reconcileMirrors] so concurrent calls (hotplug listener,
  /// `setActiveProfile`, undo/redo, `setMirror`) cannot interleave inside
  /// `MirrorRunner` and clobber each other's `_entries[dst]` state. Each
  /// `_reconcileMirrors()` chains `_doReconcileMirrors` onto the previous
  /// future; failures are caught at the chain boundary so a poisoned run
  /// can't block subsequent reconciles.
  Future<void> _reconcileChain = Future.value();
  /// Set in [dispose] before `super.dispose()`. Async paths that survive
  /// past dispose (the hotplug listener body, fire-and-forget reconciles,
  /// callbacks the controller fires after awaiting work) check this and
  /// short-circuit so a stale event can't drive `notifyListeners` on a
  /// disposed `ChangeNotifier` (asserts in debug) or fire UI callbacks
  /// against a disposed widget.
  bool _isDisposed = false;
  /// Set during [init] when the live kanshi config carries `include`
  /// directives. While true, all save paths short-circuit and fire
  /// [onConfigSaveBlocked] instead of writing — overwriting would
  /// orphan profiles in the included files.
  bool _configHasIncludes = false;
  bool get configHasIncludes => _configHasIncludes;
  final Map<String, MonitorMode> _lastModeBeforeCustom = {};
  final Map<String, double> _lastSnappedScale = {};
  List<SnapLine> _activeSnapLines = const [];
  StreamSubscription<List<MonitorTileData>>? _outputSubscription;
  void Function(String message)? onHotplugToast;
  /// Fired after a hotplug event when the connected output set matches a
  /// non-active profile better than the currently active one (confidence
  /// > 0.5). The HomePage typically surfaces this as a SnackBar with a
  /// "Switch" action; the controller never auto-switches on its own
  /// from the suggestion path.
  void Function(ProfileSuggestion suggestion)? onProfileSuggestion;
  /// Pulled by the hotplug listener to decide whether to auto-switch on
  /// an exact profile match. Defaults to "no" so the controller stays
  /// inert until the host page wires its AppSettings flag in. Returning
  /// false keeps the legacy suggestion-toast behaviour.
  bool Function()? autoSwitchProfileEnabled;
  /// Fired after the hotplug listener auto-switches to a matching
  /// profile. The HomePage surfaces this as a non-blocking toast with
  /// an Undo action. Distinct from [onProfileSuggestion] because the
  /// switch already happened — the toast is informational, not a
  /// prompt.
  void Function(String profileName)? onAutoSwitchedProfile;
  /// Fired when a save was attempted but skipped because the user's
  /// kanshi config uses `include` directives (saving would orphan
  /// profiles in the included files). The HomePage surfaces this as
  /// a persistent SnackBar so the user knows why their changes are
  /// not landing on disk.
  void Function()? onConfigSaveBlocked;
  /// Wallclock of the last manual profile switch. Auto-suggestions are
  /// suppressed for [_suggestionCooldown] after this so a user who just
  /// picked profile A on purpose doesn't get nagged into switching back.
  DateTime? _lastManualProfileSwitchAt;
  static const Duration _suggestionCooldown = Duration(seconds: 30);

  /// Undo/redo history. Each entry is a deep snapshot of `_profiles` and
  /// the active index taken just before a mutation. The stacks are LIFO;
  /// pushing onto undo clears redo, undoing pops onto redo, redoing pops
  /// onto undo. Capped at [_historyCap] entries to keep memory bounded.
  final List<_HistoryEntry> _undoStack = [];
  final List<_HistoryEntry> _redoStack = [];
  static const int _historyCap = 30;
  Map<String, int> _identifyNumbers = const {};
  Timer? _identifyTimer;
  final List<ProcessStream> _identifyBanners = [];
  final Map<String, _DragSession> _dragSessions = {};
  static const _alignmentEscapeLimit = 2;
  Rect? _pinnedLayoutBounds;
  /// Monotonically increasing token bumped whenever in-flight drag state
  /// is invalidated (hotplug clearing sessions, profile switch, etc.).
  /// Tiles snapshot this on `beginDragSession` and treat any later
  /// `onPanUpdate` / `onPanEnd` whose snapshot doesn't match the current
  /// epoch as stale — they snap back instead of writing into a session
  /// the controller has already torn down.
  int _dragCancelEpoch = 0;

  /// Scale values the slider rasters onto on release. Chosen for real-world
  /// HiDPI scenarios; intentionally excludes integer scales > 3 because
  /// they are essentially never useful and would create the "I can't get
  /// off 1.0" trap if every integer were a magnet.
  static const _scaleSnapValues = <double>[
    1.0, 1.25, 1.333, 1.5, 1.75, 2.0, 2.5, 3.0,
  ];
  static const _scaleSnapTolerance = 0.03;

  KanshiController({
    required this.monitors,
    required this.config,
    MirrorRunner? mirrorRunner,
    this.snapThreshold = 60.0,
  }) : mirrorRunner = mirrorRunner ?? MirrorRunner() {
    config.writeOptions = monitors.writeOptions;
    safetyNet.onChange((_) => notifyListeners());
    // The runner mutates failedDestinations / activeDestinations on
    // wl-mirror exits. UI surfaces that via this controller's
    // notifyListeners pipeline.
    this.mirrorRunner.addListener(notifyListeners);
  }

  // ── Read-only accessors ────────────────────────────────────────────────
  /// Snapshot of the cancel-epoch at the time of the call. Tiles record
  /// this in `beginDragSession` and compare it on every drag update; a
  /// mismatch means an external event (hotplug, profile switch) tore
  /// down the drag and the gesture should be aborted to its start
  /// position.
  int get dragCancelEpoch => _dragCancelEpoch;
  List<Profile> get profiles => List.unmodifiable(_profiles);
  List<MonitorTileData> get currentMonitors =>
      List.unmodifiable(_currentMonitors);
  int? get activeProfileIndex => _activeProfileIndex;
  Profile? get activeProfile =>
      _activeProfileIndex == null ? null : _profiles[_activeProfileIndex!];
  List<MonitorTileData> get activeMonitors =>
      activeProfile?.monitors ?? const [];
  bool get isApplyingBatch => _isApplyingBatch;
  bool get supportsLiveApply => monitors.isLive;
  /// True when there's a snapshot to roll back to via [undo].
  bool get canUndo => _undoStack.isNotEmpty;
  /// True when [redo] has a snapshot to replay.
  bool get canRedo => _redoStack.isNotEmpty;
  /// Human-readable label of the most recent undoable mutation, or null
  /// when the stack is empty. Used by the UI for tooltips like
  /// "Undo: toggle DP-1".
  String? get nextUndoLabel =>
      _undoStack.isEmpty ? null : _undoStack.last.label;
  String? get nextRedoLabel =>
      _redoStack.isEmpty ? null : _redoStack.last.label;
  bool get supportsMirror => monitors.supportsMirror;
  List<SnapLine> get activeSnapLines => List.unmodifiable(_activeSnapLines);

  /// Bounding box (in absolute monitor space) the canvas should pin its
  /// projection to. Non-null only while a drag session is active. Without
  /// this, dragging a monitor into negative coordinates (e.g. above origin)
  /// would shift `minX`/`minY` every frame, causing the entire layout —
  /// including non-dragged tiles — to reflow under the cursor and produce
  /// "duplicate" / overlapping ghost imprints.
  Rect? get pinnedLayoutBounds => _pinnedLayoutBounds;
  Map<String, int> get identifyNumbers =>
      Map.unmodifiable(_identifyNumbers);
  bool get isIdentifying => _identifyNumbers.isNotEmpty;

  /// Flashes a numbered overlay on each active monitor tile for ~3 seconds
  /// so the user can map "tile 1 ↔ physical screen 1". The numbering goes
  /// left-to-right, top-to-bottom by absolute position.
  void identifyDisplays() {
    final mons = activeMonitors.where((m) => m.enabled).toList();
    if (mons.isEmpty) return;
    final sorted = [...mons]..sort((a, b) {
        final byY = a.y.compareTo(b.y);
        if (byY != 0) return byY;
        return a.x.compareTo(b.x);
      });
    final numbers = <String, int>{
      for (var i = 0; i < sorted.length; i++) sorted[i].id: i + 1,
    };
    _identifyNumbers = numbers;
    _identifyTimer?.cancel();

    // Spawn an on-screen banner per physical output so the user can map
    // "tile N in the GUI" → "screen N in front of me". Backends that
    // can't target a specific output return null — for those we fall
    // back to the in-GUI overlay only.
    _killIdentifyBanners();
    for (final entry in numbers.entries) {
      // Skip mirrored tiles — their banner would render on the source's
      // pixels, leading to two banners on the same physical screen.
      final tile = sorted.firstWhere((m) => m.id == entry.key);
      if (tile.mirrorOf != null) continue;
      final ps = monitors.spawnIdentifyBanner(
          _resolveOutputName(entry.key), entry.value.toString());
      if (ps != null) {
        _identifyBanners.add(ps);
        // Drain stdout to keep the pipe from blocking the child.
        ps.lines.listen((_) {}, onError: (_) {}, cancelOnError: false);
      }
    }

    _identifyTimer = Timer(const Duration(seconds: 3), () {
      _identifyNumbers = const {};
      _killIdentifyBanners();
      notifyListeners();
    });
    notifyListeners();
  }

  void _killIdentifyBanners() {
    for (final ps in _identifyBanners) {
      // ignore: discarded_futures
      ps.kill();
    }
    _identifyBanners.clear();
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────
  Future<void> init() async {
    await _loadConfig();
    await refreshConnectedMonitors();
    // Detect include directives BEFORE `ensureCurrentSetupMatches` —
    // that helper schedules a save, and we want the include-block
    // flag to be in place so the schedule short-circuits cleanly
    // instead of throwing later from inside the debounce timer.
    try {
      _configHasIncludes = await config.hasIncludeDirectives();
    } catch (_) {
      _configHasIncludes = false;
    }
    await ensureCurrentSetupMatches();
    _subscribeHotplug();
    await _reconcileMirrors();
    // Self-healing pass: kanshi's `exec swaymsg "…"` chain ran once
    // when it activated the profile, but on a cold boot that exec
    // can race against sway's output discovery — if an output isn't
    // yet known by name when the chain fires, sway silently drops the
    // affected `output 'X'` targets and workspaces land in whatever
    // order they were first created (typically reverse of left-to-
    // right). Verify the live mapping against the desired one and
    // reapply only on mismatch. Idempotent and best-effort: any
    // backend that doesn't speak swaymsg returns an empty map and
    // this becomes a no-op.
    await _verifyAndFixWorkspacePlacement();
  }

  /// Reads the live `workspace_number → output_name` mapping from the
  /// compositor, compares it to the mapping the active profile would
  /// produce, and reapplies the chained swaymsg command if they differ.
  /// Called after [init] to recover from cold-boot races where kanshi's
  /// own exec hook ran against a not-yet-settled output set.
  ///
  /// Best-effort: any failure (`getWorkspaceOutputs` throws, the chain
  /// returns non-zero) is logged and swallowed — this is a robustness
  /// nicety, not a correctness invariant. The next hotplug will re-run
  /// the chain via kanshi's own exec line in any case.
  /// [force] = true bypasses the live-state mismatch check and runs the
  /// chain unconditionally. Callers that just MUTATED the active profile
  /// (e.g. `setMirror`, profile switches) want this, because
  /// `kanshictl reload` does NOT re-fire the `exec swaymsg "…"` line on
  /// a still-active profile — sway is left with the OLD bindings while
  /// the GUI's in-memory model has the new ones. Force-apply makes the
  /// declarations land. The chain is idempotent enough that re-running
  /// is cheap (declarations no-op, focus dances end at ws 1).
  Future<void> _verifyAndFixWorkspacePlacement({bool force = false}) async {
    if (_isDisposed) return;
    if (!monitors.isLive) return;
    // The chain only makes sense on backends that opt in to the Sway
    // workspace exec — on wlr-randr / niri / etc. the writer doesn't
    // emit one in the first place and the live `get_workspaces` IPC
    // doesn't exist. Short-circuit explicitly so we don't burn an
    // IPC round-trip just to read an empty map back from the default
    // no-op impl.
    if (!monitors.writeOptions.injectSwayWorkspaceExec) return;
    final activeIdx = _activeProfileIndex;
    if (activeIdx == null) return;
    try {
      // Compute the desired mapping from the active profile's enabled,
      // non-mirror outputs — the same predicate the writer applies when
      // rendering the kanshi exec line.
      final desiredMons = _profiles[activeIdx]
          .monitors
          .where((m) => m.enabled && m.mirrorOf == null)
          .toList();
      if (desiredMons.isEmpty) return;
      // Resolve the desired mapping against *live* output ids — a
      // profile's monitor.id may be a manufacturer fallback that doesn't
      // match what sway currently calls the port. _resolveOutputName
      // does the lookup; skip outputs we can't resolve to a live name
      // (they'd produce sway warnings either way).
      final connectedIds = _currentMonitors.map((m) => m.id).toSet();
      final resolved = <MonitorTileData>[];
      for (final m in desiredMons) {
        final live = _resolveOutputName(m.id);
        if (!connectedIds.contains(live)) continue;
        resolved.add(m.copyWith(id: live));
      }
      if (resolved.isEmpty) return;
      final ranked = resolveWorkspaceRanks(resolved);
      if (ranked.isEmpty) return;

      // Build the desired ws→output map the same way the chain does:
      // ws (1..maxWorkspaces) → ranked[(ws-1) mod n].id.
      const maxWs = 9;
      final n = ranked.length;
      final desired = <int, String>{
        for (var ws = 1; ws <= maxWs; ws++)
          ws: ranked[(ws - 1) % n].id,
      };

      Map<int, String> actual;
      try {
        actual = await monitors.getWorkspaceOutputs();
      } catch (e) {
        debugPrint('verifyWorkspacePlacement: getWorkspaceOutputs failed: $e');
        return;
      }
      if (_isDisposed) return;
      // Only check the workspaces the compositor actually has — sway
      // doesn't pre-create empty workspaces, so absence is "we'll
      // create it on first focus, the chain's `workspace number N
      // output X` already declared the home". A mismatch on any
      // *existing* workspace is what matters: it means a workspace
      // already lives on the wrong output and needs `move workspace
      // to output` to relocate.
      final mismatched = actual.entries.any((e) {
        final want = desired[e.key];
        return want != null && want != e.value;
      });
      // Orphan check: any live workspace whose number is OUTSIDE the
      // 1..maxWs range (typically a stuck ws 10 from an earlier session
      // or transient state) is also a reason to re-run the chain. The
      // chain visits every ws 1..N and ends focused on ws 1, which
      // displaces the orphan; if it was empty, sway garbage-collects it.
      final hasOrphan = actual.keys.any((k) => k < 1 || k > maxWs);
      if (!force && !mismatched && !hasOrphan) return;
      final chain = buildSwayWorkspaceChain(ranked);
      if (chain == null) return;
      try {
        await monitors.applyWorkspaceChain(chain);
      } catch (e) {
        debugPrint('verifyWorkspacePlacement: applyWorkspaceChain failed: $e');
      }
    } catch (e, st) {
      debugPrint('verifyWorkspacePlacement failed: $e\n$st');
    }
  }

  void _subscribeHotplug() {
    if (!monitors.isLive) return;
    _outputSubscription = monitors.watchOutputs().listen((newOutputs) {
      // Cancelling the subscription does NOT abort an in-flight handler;
      // the body must self-guard so a hotplug event delivered between
      // `dispose()` setting the flag and the runtime tearing the
      // listener down can't drive `notifyListeners` on a disposed
      // controller (debug assertion) or fire callbacks against widgets
      // that have already detached.
      if (_isDisposed) return;
      final oldIds = _currentMonitors.map((m) => m.id).toSet();
      final newIds = newOutputs.map((m) => m.id).toSet();
      final added = newIds.difference(oldIds);
      final removed = oldIds.difference(newIds);
      _currentMonitors = newOutputs;
      // Any in-flight drag becomes invalid the moment the connected set
      // changes — the layout it started in is no longer the layout it
      // would commit into. Cancel via the epoch token; the cancel helper
      // is a no-op when no drag is active.
      if (removed.isNotEmpty || added.isNotEmpty) {
        _cancelInFlightDrags();
      }
      _rehydrateProfilesAgainst(newOutputs);
      // Auto-switch takes precedence over the suggestion toast. We only
      // act on an *exact* match (every connected output claims a
      // distinct profile slot via id-then-manufacturer) so the user
      // doesn't get yanked out of a manually-chosen profile by a fuzzy
      // partial match. The suggestion path still covers fuzzy matches.
      final didAutoSwitch = _maybeAutoSwitchProfile();
      // Reconcile any wl-mirror processes against the new connected set —
      // a yanked source/destination ends naturally on its own, but a
      // re-attached mirror partner needs a respawn. setActiveProfile
      // already triggered a reconcile when we auto-switched; only fire
      // a fresh one when no switch happened.
      if (!didAutoSwitch) {
        // ignore: discarded_futures
        _reconcileMirrors();
        _maybeFireProfileSuggestion();
      }
      notifyListeners();
      for (final id in added) {
        onHotplugToast?.call('$id connected');
      }
      for (final id in removed) {
        onHotplugToast?.call('$id disconnected');
      }
    });
  }

  /// Returns true when the listener actually switched profiles. The
  /// caller uses this to suppress the suggestion-toast (which would
  /// otherwise fire for a *different* fuzzy match the same hotplug
  /// event uncovered) and the redundant mirror-reconcile pass.
  bool _maybeAutoSwitchProfile() {
    if (autoSwitchProfileEnabled?.call() != true) return false;
    final since = _lastManualProfileSwitchAt;
    if (since != null &&
        DateTime.now().difference(since) < _suggestionCooldown) {
      return false;
    }
    final matchIdx = _findProfileMatchingCurrent();
    if (matchIdx == null) return false;
    if (matchIdx == _activeProfileIndex) return false;
    final name = _profiles[matchIdx].name;
    setActiveProfile(matchIdx, isManual: false);
    onAutoSwitchedProfile?.call(name);
    return true;
  }

  @override
  void dispose() {
    // Set the dispose flag FIRST so any in-flight async body that's
    // about to call `notifyListeners` or fire a callback bails out
    // before touching the post-dispose controller.
    _isDisposed = true;
    _saveTimer?.cancel();
    _revertScheduler.cancelAll();
    safetyNet.cancelAll();
    _outputSubscription?.cancel();
    _identifyTimer?.cancel();
    _killIdentifyBanners();
    mirrorRunner.removeListener(notifyListeners);
    // ignore: discarded_futures
    mirrorRunner.stopAll();
    super.dispose();
  }

  // ── Profile mutations ──────────────────────────────────────────────────
  Future<void> _loadConfig() async {
    _profiles = await config.loadProfiles();
    _activeProfileIndex = _findProfileMatchingCurrent() ??
        (_profiles.isNotEmpty ? 0 : null);
    notifyListeners();
  }

  Future<void> refreshConnectedMonitors() async {
    if (!monitors.isLive) {
      _currentMonitors = [];
      notifyListeners();
      return;
    }
    try {
      _currentMonitors = await monitors.getOutputs();
      _rehydrateProfilesAgainst(_currentMonitors);
      notifyListeners();
    } catch (e) {
      debugPrint('refreshConnectedMonitors failed: $e');
    }
  }

  /// Walks every profile and refreshes the per-monitor `id`, `manufacturer`,
  /// `refresh` and `modes` from the connected outputs in [live]. Matches in
  /// two passes so identical-EDID dual-monitor setups (same make/model on
  /// two ports) do not all collapse onto the first connected output:
  ///   1. exact `id` match (Sway's per-port output name) wins first;
  ///   2. only the leftover, unmatched profile entries fall back to a
  ///      manufacturer-string match against the still-unclaimed live
  ///      outputs.
  /// Without the two-pass rule a profile with two "Samsung 2560×1440"
  /// entries would re-hydrate both from whichever live output appears
  /// first in the list, silently swapping mode lists between the two
  /// physical screens.
  void _rehydrateProfilesAgainst(List<MonitorTileData> live) {
    for (final profile in _profiles) {
      final claimed = <int>{};
      // Pass 1: exact id matches.
      for (var i = 0; i < profile.monitors.length; i++) {
        final pe = profile.monitors[i];
        if (pe.id.isEmpty) continue;
        for (var j = 0; j < live.length; j++) {
          if (claimed.contains(j)) continue;
          if (_matchesOutput(live[j].id, pe.id)) {
            claimed.add(j);
            profile.monitors[i] = pe.copyWith(
              id: live[j].id,
              manufacturer: live[j].manufacturer,
              refresh: live[j].refresh,
              modes: live[j].modes,
            );
            break;
          }
        }
      }
      // Pass 2: manufacturer fallback for entries that did not get an id
      // hit. We have to rescan because pass 1 may have updated `id` fields
      // we now want to skip.
      for (var i = 0; i < profile.monitors.length; i++) {
        final pe = profile.monitors[i];
        // Skip entries that were already matched in pass 1 by checking
        // whether their id is currently claimed.
        final alreadyClaimed = live.indexWhere(
                (m) => _matchesOutput(m.id, pe.id)) !=
            -1 &&
            claimed.contains(
                live.indexWhere((m) => _matchesOutput(m.id, pe.id)));
        if (alreadyClaimed) continue;
        if (pe.manufacturer.isEmpty) continue;
        for (var j = 0; j < live.length; j++) {
          if (claimed.contains(j)) continue;
          if (_matchesOutput(live[j].manufacturer, pe.manufacturer)) {
            claimed.add(j);
            profile.monitors[i] = pe.copyWith(
              id: live[j].id,
              manufacturer: live[j].manufacturer,
              refresh: live[j].refresh,
              modes: live[j].modes,
            );
            break;
          }
        }
      }
    }
  }

  Future<void> ensureCurrentSetupMatches() async {
    final matchIdx = _findProfileMatchingCurrent();
    if (matchIdx != null) {
      _activeProfileIndex = matchIdx;
    } else {
      const currentName = 'Current Setup';
      final idx = _profiles.indexWhere((p) => p.name == currentName);
      if (idx == -1) {
        _profiles.add(Profile(name: currentName, monitors: _currentMonitors));
        _activeProfileIndex = _profiles.length - 1;
      } else {
        _profiles[idx] =
            Profile(name: currentName, monitors: _currentMonitors);
        _activeProfileIndex = idx;
      }
    }

    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) {
      final marker = File('$home/.config/kanshi/current');
      try {
        await marker.create(recursive: true);
        await marker.writeAsString(activeProfile?.name ?? 'Current Setup');
      } catch (e) {
        debugPrint('failed to write current profile marker: $e');
      }
    }
    _scheduleSave();
    notifyListeners();
  }

  /// Snapshot the current profile state onto the undo stack so the
  /// matching mutation can be rolled back. Pass [overrides] when the
  /// "before" state isn't simply the current state — e.g. a drag has
  /// already mutated the active profile to mid-drag positions and we
  /// want the snapshot to reflect the pre-drag rollback. Pushing also
  /// clears the redo stack: a fresh mutation invalidates any prior
  /// "forward" history.
  void _pushHistory(
    String label, {
    Map<String, MonitorTileData>? overrides,
  }) {
    final snap = <Profile>[];
    for (var i = 0; i < _profiles.length; i++) {
      final p = _profiles[i];
      final mons = [...p.monitors];
      if (i == _activeProfileIndex && overrides != null) {
        for (var j = 0; j < mons.length; j++) {
          final ov = overrides[mons[j].id];
          if (ov != null) mons[j] = ov;
        }
      }
      snap.add(Profile(name: p.name, monitors: mons));
    }
    _undoStack.add(_HistoryEntry(
      profiles: snap,
      activeIndex: _activeProfileIndex,
      label: label,
    ));
    while (_undoStack.length > _historyCap) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// Reverts the most recent mutation by replacing `_profiles` and the
  /// active index with the top of the undo stack, pushing the current
  /// state onto the redo stack so it can be replayed via [redo].
  /// Schedules a save and reload so the compositor catches up.
  Future<OpResult> undo() async {
    if (_undoStack.isEmpty) return const OpResult.err('Nothing to undo.');
    final entry = _undoStack.removeLast();
    _redoStack.add(_currentSnapshot(entry.label));
    while (_redoStack.length > _historyCap) {
      _redoStack.removeAt(0);
    }
    await _restoreSnapshot(entry);
    return OpResult.ok('Undone: ${entry.label}');
  }

  Future<OpResult> redo() async {
    if (_redoStack.isEmpty) return const OpResult.err('Nothing to redo.');
    final entry = _redoStack.removeLast();
    _undoStack.add(_currentSnapshot(entry.label));
    while (_undoStack.length > _historyCap) {
      _undoStack.removeAt(0);
    }
    await _restoreSnapshot(entry);
    return OpResult.ok('Redone: ${entry.label}');
  }

  _HistoryEntry _currentSnapshot(String label) => _HistoryEntry(
        profiles: [
          for (final p in _profiles)
            Profile(name: p.name, monitors: [...p.monitors]),
        ],
        activeIndex: _activeProfileIndex,
        label: label,
      );

  Future<void> _restoreSnapshot(_HistoryEntry entry) async {
    final activeChanged = _activeProfileIndex != entry.activeIndex;
    _profiles = [
      for (final p in entry.profiles)
        Profile(name: p.name, monitors: [...p.monitors]),
    ];
    _activeProfileIndex = entry.activeIndex;
    // If undoing rolled the user *back* to a different active profile
    // (e.g. they hit Undo on the auto-switch toast), arm the
    // suggestion-cooldown so a flaky cable wiggle doesn't immediately
    // bounce the auto-switcher right back to the profile we just
    // walked away from. Treat the undo itself as the user's "manual"
    // intent.
    if (activeChanged) {
      _lastManualProfileSwitchAt = DateTime.now();
    }
    // Cancel any in-flight drag — its rollback origin is no longer
    // valid against the restored profile shape.
    _cancelInFlightDrags();
    // Cancel any pending auto-revert from a custom-mode apply that may
    // have been undone away. Without this, a 15-second timer scheduled
    // by `applyCustomMode` would fire after an undo and re-apply a
    // pre-custom mode the user no longer expects.
    _revertScheduler.cancelAll();
    safetyNet.cancelAll();
    // Bypass the 600ms save debounce so the kanshictl reload fired
    // by _flushSaveAndReload reads the restored config, not whatever
    // a future debounced write would have produced.
    await _flushSaveAndReload();
    await _reconcileMirrors();
    notifyListeners();
  }

  /// Cancels the debounced save timer, writes the current `_profiles`
  /// to disk, and triggers a `kanshictl reload`. All best-effort: any
  /// failure surfaces as a stale config or non-restarted compositor,
  /// but the in-memory state is already consistent so the GUI keeps
  /// working. Used by every code path that needs the kanshi reload to
  /// see the just-written config (mirror / rank / undo / redo).
  Future<void> _flushSaveAndReload() async {
    _saveTimer?.cancel();
    if (_configHasIncludes) {
      // The user's main config pulls in other files via `include`.
      // Saving would render only the profiles WE parsed (which
      // didn't include the included files') and silently overwrite
      // the include line — orphaning every profile in the included
      // files. Surface a UI warning instead.
      onConfigSaveBlocked?.call();
      return;
    }
    try {
      await config.saveProfiles(_profiles);
    } on ConfigHasIncludesException {
      // Race-safe fallback: if the user added an `include` directive
      // since `init()` ran (we cached the answer there), the
      // ConfigService throws this and we surface the same warning
      // path as the upfront block.
      _configHasIncludes = true;
      onConfigSaveBlocked?.call();
    } catch (_) {/* best effort */}
    try {
      await monitors.restartCompositorProfileApply();
    } catch (_) {/* best effort */}
  }

  /// Switch to profile [index]. [isManual] is true for user-driven
  /// changes (sidebar click, suggestion-toast button) and false for
  /// the hotplug auto-switch path. Only manual switches arm the
  /// suggestion-cooldown so the auto-switch path doesn't accidentally
  /// silence its own future suggestions.
  void setActiveProfile(int index, {bool isManual = true}) {
    if (index < 0 || index >= _profiles.length) return;
    if (_activeProfileIndex != index) {
      _pushHistory("activate '${_profiles[index].name}'");
    }
    _activeProfileIndex = index;
    if (isManual) {
      _lastManualProfileSwitchAt = DateTime.now();
    }
    // A profile switch invalidates any in-flight drag — the layout it
    // started in is no longer the layout we'd commit into. Cancel via
    // the epoch token; the tile will snap back to its pre-drag origin.
    _cancelInFlightDrags();
    // The "revert custom mode" memory is per-output but profile-scoped in
    // intent — a custom mode applied while Profile A was active should not
    // be revertable from Profile B (the prior mode belongs to A's idea of
    // the layout). Drop the cache on every profile switch so the next
    // revert call surfaces a clean error instead of restoring something
    // surprising.
    _lastModeBeforeCustom.clear();
    _revertScheduler.cancelAll();
    // Profile mirrors are per-profile: tear down everything that belongs
    // to the previous profile and let _reconcileMirrors stand up the new
    // ones. Do this even when the index is unchanged so a manual switch
    // back to the same profile heals any drift.
    // ignore: discarded_futures
    _reconcileMirrors();
    notifyListeners();
  }

  OpResult renameProfile(int index, String newName) {
    if (index < 0 || index >= _profiles.length) {
      return const OpResult.err('Profile index out of range.');
    }
    final exists = _profiles.any((p) =>
        p.name.toLowerCase() == newName.toLowerCase() &&
        p != _profiles[index]);
    if (exists) {
      return const OpResult.err('Profile name already exists!');
    }
    _pushHistory("rename '${_profiles[index].name}' → '$newName'");
    _profiles[index].name = newName;
    _scheduleSave();
    notifyListeners();
    return const OpResult.ok();
  }

  void deleteProfile(int index) {
    if (index < 0 || index >= _profiles.length) return;
    _pushHistory("delete '${_profiles[index].name}'");
    final wasActive = _activeProfileIndex;
    _profiles.removeAt(index);
    // Adjust the active index so it keeps pointing at the same Profile
    // object after the removal:
    //   - exactly the deleted profile  → no active profile
    //   - active index sits *after* the deleted one → shift down by one
    //   - active index sits *before*   → unchanged
    if (wasActive != null) {
      if (wasActive == index) {
        _activeProfileIndex = null;
      } else if (wasActive > index) {
        _activeProfileIndex = wasActive - 1;
      }
    }
    _scheduleSave();
    notifyListeners();
  }

  void createProfileFromCurrentSetup() {
    _pushHistory('create profile');
    final newProfile = Profile(
      name: 'Current Setup',
      monitors: _currentMonitors.map((m) {
        return m.rotation % 180 == 0
            ? m.copyWith(orientation: 'landscape')
            : m.copyWith(
                width: m.height,
                height: m.width,
                orientation: 'portrait',
              );
      }).toList(),
    );
    _profiles.add(newProfile);
    _activeProfileIndex = _profiles.length - 1;
    _scheduleSave();
    notifyListeners();
  }

  // ── Monitor-level mutations within the active profile ──────────────────
  void updateMonitor(MonitorTileData updated) {
    if (_activeProfileIndex == null) return;
    final mons = _profiles[_activeProfileIndex!].monitors;
    final idx = mons.indexWhere((m) => m.id == updated.id);
    if (idx == -1) return;
    if (!mons[idx].enabled) return;
    final prevRotation = mons[idx].rotation;
    mons[idx] = updated;
    _scheduleSave();
    notifyListeners();
    // Rotation changes don't get a drag-end / commit callback — live-apply
    // them right away so the compositor matches the visual state.
    if (updated.rotation != prevRotation) {
      // Fire-and-forget; UI doesn't await this.
      // ignore: discarded_futures
      pushLiveApply(updated);
    }
  }

  /// Updates the scale of [id] and adjusts neighbours that were edge-snapped
  /// to it so they stay aligned. When [committing] is true (mouse-up / final
  /// commit), the new value rasters onto the nearest entry in
  /// [_scaleSnapValues] within tolerance — *unless* the user just left a
  /// snap value (tracked in [_lastSnappedScale]) and hasn't moved far
  /// enough away from it yet (direction-aware snapping). When false (during
  /// drag), no snap is applied so the user gets immediate, unfiltered
  /// feedback and never feels "stuck" near 1.0.
  void scaleMonitor(String id, double newScale, {bool committing = false}) {
    if (_activeProfileIndex == null) return;
    if (committing) {
      newScale = _maybeSnapScale(id, newScale);
    }
    newScale = double.parse(newScale.toStringAsFixed(2));

    final mons = [..._profiles[_activeProfileIndex!].monitors];
    final idx = mons.indexWhere((m) => m.id == id);
    if (idx == -1 || !mons[idx].enabled) return;
    // Only the commit step is undoable. Mid-slider drags would otherwise
    // pollute the undo stack with one entry per pixel, which makes the
    // user-facing semantics of Ctrl+Z unintuitive.
    if (committing) {
      _pushHistory('scale $id to ${newScale.toStringAsFixed(2)}');
    }

    // BFS over the *pre-change* edge graph: when monitor A moves, any
    // monitor B that was edge-snapped to A in the original layout has
    // to follow, and any C that was snapped to B follows B, and so on.
    // Without this, only the scaled tile's direct neighbours stay
    // flush; a 3-monitor chain (A → B → C) loses contact between B
    // and C the moment A's scale changes.
    final originals = [for (final m in mons) m];
    final centre = mons[idx];
    mons[idx] = centre.copyWith(scale: newScale);
    final visited = <int>{idx};
    final queue = <int>[idx];
    while (queue.isNotEmpty) {
      final ci = queue.removeAt(0);
      final origC = originals[ci];
      final newC = mons[ci];
      final origCRight = origC.x + origC.width / origC.scale;
      final origCBottom = origC.y + origC.height / origC.scale;
      final newCRight = newC.x + newC.width / newC.scale;
      final newCBottom = newC.y + newC.height / newC.scale;
      for (var i = 0; i < mons.length; i++) {
        if (visited.contains(i)) continue;
        final origOther = originals[i];
        var x = mons[i].x;
        var y = mons[i].y;
        var moved = false;
        if ((origOther.x - origCRight).abs() <= snapThreshold) {
          x = newCRight;
          moved = true;
        } else if (((origOther.x + origOther.width / origOther.scale) -
                    origC.x)
                .abs() <=
            snapThreshold) {
          x = newC.x - origOther.width / origOther.scale;
          moved = true;
        }
        if ((origOther.y - origCBottom).abs() <= snapThreshold) {
          y = newCBottom;
          moved = true;
        } else if (((origOther.y + origOther.height / origOther.scale) -
                    origC.y)
                .abs() <=
            snapThreshold) {
          y = newC.y - origOther.height / origOther.scale;
          moved = true;
        }
        if (moved) {
          mons[i] = mons[i].copyWith(x: x, y: y);
          visited.add(i);
          queue.add(i);
        }
      }
    }
    _profiles[_activeProfileIndex!] =
        Profile(name: _profiles[_activeProfileIndex!].name, monitors: mons);
    _scheduleSave();
    notifyListeners();
  }

  void snapAndCommit(MonitorTileData dragged, MonitorTileData? rollbackTo) {
    if (_activeProfileIndex == null) return;
    final mons = [..._profiles[_activeProfileIndex!].monitors];
    final idx = mons.indexWhere((m) => m.id == dragged.id);
    if (idx == -1 || !mons[idx].enabled) return;
    // Push pre-drag state: snapshot reflects the rollback (what the
    // user would see if they had not dragged) so undo restores their
    // original layout, not the last mid-drag frame's position.
    _pushHistory(
      "move ${dragged.id}",
      overrides:
          rollbackTo != null ? {dragged.id: rollbackTo} : null,
    );
    final session = _dragSessions[dragged.id];
    // Only enabled, non-mirrored monitors are real snap / overlap
    // targets — disabled tiles and mirror tiles are rendered parked
    // beside the active cluster, not at their stored coordinates, so
    // snapping or overlap-checking against their raw position would
    // offer phantom targets the user cannot see.
    final activeOnly =
        mons.where((m) => m.enabled && m.mirrorOf == null).toList();
    final activeIdx = activeOnly.indexWhere((m) => m.id == dragged.id);
    final result = LayoutMath.snapToEdges(
      mons[idx],
      activeOnly,
      snapThreshold,
      yAlignmentEnabled:
          (session?.yEscapeCount ?? 0) < _alignmentEscapeLimit,
      xAlignmentEnabled:
          (session?.xEscapeCount ?? 0) < _alignmentEscapeLimit,
    );
    mons[idx] = result.tile;
    activeOnly[activeIdx] = result.tile;
    if (LayoutMath.hasOverlap(result.tile, activeOnly, activeIdx) &&
        rollbackTo != null) {
      mons[idx] = rollbackTo;
    }
    _profiles[_activeProfileIndex!] =
        Profile(name: _profiles[_activeProfileIndex!].name, monitors: mons);
    _activeSnapLines = const [];
    _scheduleSave();
    notifyListeners();
  }

  /// UI calls this when a fresh drag starts (mouse down on a tile). Resets
  /// the per-monitor alignment-escape memory so the user gets the full
  /// alignment hints again, and snapshots the canvas bounding box so the
  /// projection stays put while the user drags. Without the snapshot, the
  /// dragged tile pushing the bounding box outward (e.g. negative Y when
  /// stacked above origin) would re-scale and re-offset every other tile
  /// every frame.
  /// Returns the cancel-epoch the caller should compare against during
  /// the drag. If `controller.dragCancelEpoch` later differs, the drag
  /// has been invalidated externally (hotplug, profile switch) and the
  /// caller must treat the gesture as cancelled. The optional [rollback]
  /// snapshot captures the tile state at drag-start so a cancellation
  /// can restore the profile to what it was before the drag began.
  int beginDragSession(String id, [MonitorTileData? rollback]) {
    _dragSessions[id] = _DragSession()..rollbackOrigin = rollback;
    if (_activeProfileIndex != null) {
      // Pin against the truly-independent active cluster only — mirror
      // tiles and disabled ones are parked, so pinning a bounding box
      // that includes them would freeze the canvas around phantom
      // positions.
      final mons = _profiles[_activeProfileIndex!]
          .monitors
          .where((m) => m.enabled && m.mirrorOf == null)
          .toList();
      if (mons.isNotEmpty) {
        _pinnedLayoutBounds = LayoutMath.boundingBox(mons);
        notifyListeners();
      }
    }
    return _dragCancelEpoch;
  }

  /// Cancel every in-flight drag session: roll the profile back to each
  /// session's pre-drag snapshot, drop the alignment-escape state, free
  /// the pinned bounding box, and bump the cancel-epoch so any tile
  /// mid-gesture detects the invalidation and snaps back. No-op when
  /// there are no active sessions and no pinned bounds.
  void _cancelInFlightDrags() {
    if (_dragSessions.isEmpty && _pinnedLayoutBounds == null) return;
    if (_activeProfileIndex != null) {
      final mons = [..._profiles[_activeProfileIndex!].monitors];
      var dirty = false;
      for (final entry in _dragSessions.entries) {
        final rollback = entry.value.rollbackOrigin;
        if (rollback == null) continue;
        final idx = mons.indexWhere((m) => m.id == entry.key);
        if (idx == -1) continue;
        mons[idx] = rollback;
        dirty = true;
      }
      if (dirty) {
        _profiles[_activeProfileIndex!] = Profile(
          name: _profiles[_activeProfileIndex!].name,
          monitors: mons,
        );
      }
    }
    _dragSessions.clear();
    _pinnedLayoutBounds = null;
    _dragCancelEpoch++;
  }

  /// UI calls this when the drag ends (mouse up). Clears the session so the
  /// next grab is fresh and releases the layout pin so the canvas reflows
  /// to the post-drag state.
  void endDragSession(String id) {
    _dragSessions.remove(id);
    if (_pinnedLayoutBounds != null) {
      _pinnedLayoutBounds = null;
      notifyListeners();
    }
  }

  /// Computes the snap result for [dragged] without mutating any state and
  /// publishes the active snap lines so the UI can render guide lines while
  /// the drag is in progress. Tracks alignment-escape: if the user pulls
  /// the tile out of an active alignment snap twice within the same drag
  /// session, that axis's alignment magnet stays off until the next grab.
  void previewSnap(MonitorTileData dragged) {
    if (_activeProfileIndex == null) {
      if (_activeSnapLines.isNotEmpty) {
        _activeSnapLines = const [];
        notifyListeners();
      }
      return;
    }
    final mons = _profiles[_activeProfileIndex!]
        .monitors
        .where((m) => m.enabled && m.mirrorOf == null)
        .toList();
    final session = _dragSessions[dragged.id];
    final result = LayoutMath.snapToEdges(
      dragged,
      mons,
      snapThreshold,
      yAlignmentEnabled:
          (session?.yEscapeCount ?? 0) < _alignmentEscapeLimit,
      xAlignmentEnabled:
          (session?.xEscapeCount ?? 0) < _alignmentEscapeLimit,
    );

    if (session != null) {
      // A *transition* from "y-alignment was applied" → "no longer applied
      // even though the corresponding edge is still snapped" counts as
      // the user pulling out of the alignment.
      if (session.lastYAlignmentApplied &&
          !result.yAlignmentApplied &&
          result.xEdgeSnapped) {
        session.yEscapeCount++;
      }
      if (session.lastXAlignmentApplied &&
          !result.xAlignmentApplied &&
          result.yEdgeSnapped) {
        session.xEscapeCount++;
      }
      session.lastYAlignmentApplied = result.yAlignmentApplied;
      session.lastXAlignmentApplied = result.xAlignmentApplied;
    }

    if (!_snapLineListsEqual(_activeSnapLines, result.activeLines)) {
      _activeSnapLines = result.activeLines;
      notifyListeners();
    }
  }

  void clearSnapPreview() {
    if (_activeSnapLines.isNotEmpty) {
      _activeSnapLines = const [];
      notifyListeners();
    }
  }

  bool _snapLineListsEqual(List<SnapLine> a, List<SnapLine> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  double _maybeSnapScale(String id, double raw) {
    final last = _lastSnappedScale[id];
    double? best;
    var bestDist = double.infinity;
    for (final v in _scaleSnapValues) {
      final dist = (raw - v).abs();
      if (dist > _scaleSnapTolerance) continue;
      // Direction-aware: if we just left this value, require ~2× tolerance
      // before re-snapping to the same one — avoids the "stuck on 1.0" trap.
      if (last != null && (last - v).abs() < 1e-9) {
        if (dist > 0 && (raw - last).abs() < _scaleSnapTolerance * 2) {
          continue;
        }
      }
      if (dist < bestDist) {
        bestDist = dist;
        best = v;
      }
    }
    if (best != null) {
      _lastSnappedScale[id] = best;
      return best;
    }
    _lastSnappedScale.remove(id);
    return raw;
  }

  void rearrangeActiveLayout() {
    if (_activeProfileIndex == null) return;
    final profile = _profiles[_activeProfileIndex!];
    final active = profile.monitors.where((m) => m.enabled).toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    final inactive = profile.monitors.where((m) => !m.enabled).toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    if (active.isEmpty) return;
    _pushHistory('rearrange layout');

    const spacing = 100.0;
    var currentX = 0.0;
    final rearranged = <MonitorTileData>[];
    double advance(MonitorTileData m) =>
        m.width / (m.scale == 0 ? 1.0 : m.scale);
    for (final m in active) {
      rearranged.add(m.copyWith(x: currentX, y: 0));
      currentX += advance(m) + spacing;
    }
    for (final m in inactive) {
      rearranged.add(m.copyWith(x: currentX, y: 0));
      currentX += advance(m) + spacing;
    }
    _profiles[_activeProfileIndex!] =
        Profile(name: profile.name, monitors: rearranged);
    _scheduleSave();
    notifyListeners();
  }

  // ── Workspace rank ─────────────────────────────────────────────────────

  /// Set this monitor's left-to-right rank (0-indexed) for the
  /// interleaved Sway workspace distribution. Pass `null` to clear the
  /// override and fall back to the X-position derived rank. The change
  /// is persisted in the kanshi config (as a `# kanshi_gui:rank` comment)
  /// and a `kanshictl reload` is fired so the new workspace assignment
  /// takes effect immediately.
  Future<OpResult> setWorkspaceRank(String monitorId, int? rank) async {
    if (_activeProfileIndex == null) {
      return const OpResult.err('No active profile.');
    }
    final profile = _profiles[_activeProfileIndex!];
    final mons = [...profile.monitors];
    final idx = mons.indexWhere((m) => m.id == monitorId);
    if (idx == -1) {
      return OpResult.err('Output $monitorId not found in active profile.');
    }
    final enabledCount = mons.where((m) => m.enabled).length;
    if (rank != null && (rank < 0 || rank >= enabledCount)) {
      return OpResult.err(
          'Workspace position must be between 1 and $enabledCount.');
    }
    _pushHistory(
      rank == null
          ? 'clear workspace rank for $monitorId'
          : 'set $monitorId to workspace position ${rank + 1}',
    );
    // If another monitor already holds this rank, swap with it so all
    // ranks stay unique. Without the swap the writer's collision-resolver
    // would silently demote the other monitor to a derived rank, which is
    // surprising — explicit swap mirrors what the user likely meant.
    if (rank != null) {
      final clash = mons.indexWhere(
        (m) => m.id != monitorId && m.workspaceRank == rank,
      );
      if (clash != -1) {
        mons[clash] = mons[clash].copyWith(
          workspaceRank: mons[idx].workspaceRank,
        );
      }
    }
    mons[idx] = mons[idx].copyWith(workspaceRank: rank);
    _profiles[_activeProfileIndex!] =
        Profile(name: profile.name, monitors: mons);
    // Flush before reload to avoid a stale-config race in kanshi.
    await _flushSaveAndReload();
    notifyListeners();
    return OpResult.ok(
      rank == null
          ? '$monitorId workspace position cleared.'
          : '$monitorId now at workspace position ${rank + 1}.',
    );
  }

  // ── Mirror state ───────────────────────────────────────────────────────

  /// Toggle the mirror relationship of [destId]: pass [srcId] to make
  /// `destId` mirror `srcId`, or null to release the mirror. Validates
  /// against circular and chained mirrors (rejected as
  /// `OpResult.err`). The runner is asked to spawn / kill wl-mirror
  /// immediately; the kanshi config write is scheduled and a
  /// `kanshictl reload` is fired so kanshi knows about the change.
  Future<OpResult> setMirror(String destId, String? srcId) async {
    if (!supportsMirror) {
      return const OpResult.err(
          'Mirror is only supported on the Sway backend.');
    }
    if (_activeProfileIndex == null) {
      return const OpResult.err('No active profile.');
    }
    final mons = [..._profiles[_activeProfileIndex!].monitors];
    final destIdx = mons.indexWhere((m) => m.id == destId);
    if (destIdx == -1) {
      return OpResult.err('Output $destId not found in active profile.');
    }
    if (!mons[destIdx].enabled) {
      return const OpResult.err(
          'Cannot mirror a disabled output — enable it first.');
    }

    if (srcId != null) {
      if (srcId == destId) {
        return const OpResult.err('A monitor cannot mirror itself.');
      }
      final srcIdx = mons.indexWhere((m) => m.id == srcId);
      if (srcIdx == -1) {
        return OpResult.err('Mirror source $srcId not found in profile.');
      }
      if (!mons[srcIdx].enabled) {
        return OpResult.err('Mirror source $srcId is disabled.');
      }
      // Reject chains and cycles: the source must not itself be a
      // mirror destination (would create a chain, which Sway/wl-mirror
      // do not handle), and there must not already be a mirror going
      // the other way (A→B + B→A is a cycle).
      if (mons[srcIdx].mirrorOf != null) {
        return OpResult.err(
            'Cannot chain mirrors — $srcId already mirrors '
            '${mons[srcIdx].mirrorOf}.');
      }
      if (mons.any((m) => m.id == srcId && m.mirrorOf == destId) ||
          mons[destIdx].mirrorOf == srcId) {
        // Latter half of the OR is the no-op identity — just rebind below.
      }
      // Check for a reverse-direction mirror from src→dest (would cycle).
      final reverse = mons.firstWhere(
        (m) => m.id == srcId,
        orElse: () => mons[destIdx],
      );
      if (reverse.mirrorOf == destId) {
        return const OpResult.err(
            'Refusing to set up a circular mirror.');
      }
    }

    _pushHistory(srcId == null
        ? 'stop $destId mirroring'
        : 'mirror $destId onto $srcId');
    mons[destIdx] = mons[destIdx].copyWith(mirrorOf: srcId);
    _profiles[_activeProfileIndex!] = Profile(
      name: _profiles[_activeProfileIndex!].name,
      monitors: mons,
    );

    // Flush the save *before* reconciling and reloading. The previous
    // 600 ms-debounced save plus immediate `kanshictl reload` had a
    // race window where kanshi could read a stale config (still
    // listing the prior mirror) and re-spawn the mirror we're about
    // to tear down. Now reconcile sees the fresh desired state and
    // kanshi reads it too.
    await _flushSaveAndReload();

    // Evacuate the soon-to-be-mirrored output BEFORE wl-mirror grabs
    // it. Without this, any window living on a workspace that was on
    // the destination output (including kanshi_gui itself) gets
    // visually buried under wl-mirror's fullscreen, with no way to
    // reach it. The save+reload above re-runs the kanshi exec only
    // when the matched profile actually changes — kanshictl reload
    // is a no-op for "same profile, different config", so we cannot
    // rely on it. Driving evacuation directly fixes both that case
    // and named / >9 workspaces that the writer's 1..9 chain misses.
    if (srcId != null) {
      final connectedIds = _currentMonitors.map((m) => m.id).toSet();
      final targets = mons
          .where((m) =>
              m.enabled && m.mirrorOf == null && m.id != destId)
          .map((m) => _resolveOutputName(m.id))
          .where(connectedIds.contains)
          .toList(growable: false);
      final liveDest = _resolveOutputName(destId);
      if (targets.isNotEmpty) {
        try {
          await monitors.evacuateOutputWorkspaces(liveDest, targets);
          await monitors.waitForOutputClear(liveDest);
        } catch (e) {
          debugPrint('setMirror: evacuate failed: $e');
        }
      }
    }
    // Re-run the standard ws→output distribution: covers the un-mirror
    // case (destination is back in the ranking and needs workspaces
    // back) and rounds out the just-evacuated case. force-apply because
    // setMirror just changed the active profile's monitor set — kanshi
    // reloaded the new config but didn't re-fire its `exec swaymsg "..."`
    // chain (kanshi treats "same profile re-applied" as a no-op for
    // exec), so without forcing, sway's binding table keeps the OLD
    // ranks. Force makes the new declarations and force-moves land.
    await _verifyAndFixWorkspacePlacement(force: true);

    // Drive the live process state. _reconcileMirrors handles both
    // the "spawn new" and "kill old" cases by diffing against the
    // current desired set, plus a sweep of orphaned externals.
    // setMirror already evacuated above; tell reconcile to skip its
    // own evacuation pass so we don't redundantly IPC.
    await _reconcileMirrors(evacuateNewMirrors: false);

    notifyListeners();
    if (srcId == null) {
      return OpResult.ok('$destId no longer mirroring.');
    }
    return OpResult.ok('$destId mirrors $srcId.');
  }

  /// Diff the active profile's intended mirror set against MirrorRunner's
  /// running set, then start/stop wl-mirror processes to converge. Called
  /// from `setMirror`, `setActiveProfile`, hotplug, and `init`. Multiple
  /// concurrent calls are serialised through [_reconcileChain] — without
  /// the chain a hotplug-driven reconcile racing a profile-switch reconcile
  /// could read each other's half-installed `_entries[dst]` and kill a
  /// process the other had just spawned.
  Future<void> _reconcileMirrors({bool evacuateNewMirrors = true}) {
    final next = _reconcileChain
        .then((_) => _doReconcileMirrors(evacuate: evacuateNewMirrors));
    // The chain must NOT be poisoned by one reconcile's exception — a
    // `pgrep` IO error or a `kill` on a vanished pid would otherwise
    // block every later reconcile via the unhandled error. The inner
    // body in `_doReconcileMirrors` also catches and logs, so this
    // outer `catchError` is a defence-in-depth: if a future refactor
    // ever lets an exception escape, the chain still survives.
    _reconcileChain = next.catchError((_) {});
    return next;
  }

  Future<void> _doReconcileMirrors({bool evacuate = true}) async {
    try {
      if (!supportsMirror) {
        // Backend cannot mirror — make sure no leftovers are running.
        if (mirrorRunner.activeDestinations.isNotEmpty) {
          await mirrorRunner.stopAll();
        }
        return;
      }
      final connectedIds =
          _currentMonitors.map((m) => m.id).toSet();
      final desired = <String, String>{}; // destId -> srcId
      if (_activeProfileIndex != null) {
        for (final m in _profiles[_activeProfileIndex!].monitors) {
          final src = m.mirrorOf;
          if (src == null || !m.enabled) continue;
          // Only spin up wl-mirror when both endpoints are physically
          // present — otherwise wl-mirror would just exit, burn the retry
          // budget and mark the destination failed.
          if (!connectedIds.contains(m.id)) continue;
          if (!connectedIds.contains(src)) continue;
          desired[m.id] = src;
        }
      }
      final running = mirrorRunner.activeDestinations;

      // Stop mirrors no longer in the desired set, or whose source changed.
      for (final dst in running) {
        final wantSrc = desired[dst];
        if (wantSrc == null) {
          await mirrorRunner.stop(dst);
        }
      }
      // Start / rebind desired mirrors. Evacuate the destination output
      // FIRST when we're about to bring a brand-new mirror up — without
      // this, any workspace that lived on the destination before reconcile
      // (typical at GUI launch when kanshi has already activated the
      // profile, or after a stale session reaped wl-mirror but left the
      // dest enabled) ends up buried under wl-mirror's fullscreen layer
      // and the user can't reach those windows. Mirror `setMirror`'s
      // pipeline: evacuate, settle, then spawn.
      final connectedSet = connectedIds;
      for (final entry in desired.entries) {
        final dst = entry.key;
        final isNewMirror = !mirrorRunner.activeDestinations.contains(dst);
        if (isNewMirror && evacuate) {
          final liveDst = _resolveOutputName(dst);
          // Targets: any other connected non-mirror output the workspaces
          // can land on. Filter through the live id set so we don't ask
          // the backend to move things to a port name sway has never
          // heard of.
          final targets = (_activeProfileIndex == null
                  ? <MonitorTileData>[]
                  : _profiles[_activeProfileIndex!].monitors)
              .where((m) =>
                  m.enabled && m.mirrorOf == null && m.id != dst)
              .map((m) => _resolveOutputName(m.id))
              .where(connectedSet.contains)
              .toList(growable: false);
          if (targets.isNotEmpty) {
            try {
              await monitors.evacuateOutputWorkspaces(liveDst, targets);
              await monitors.waitForOutputClear(liveDst);
            } catch (e) {
              // Don't block the mirror startup — the worst case is a
              // window stuck under wl-mirror, which the user can recover
              // from manually. Far worse would be failing to spawn the
              // mirror at all because the evacuate path threw.
              debugPrint('reconcile: evacuate of $liveDst failed: $e');
            }
          }
        }
        await mirrorRunner.start(entry.value, dst);
      }
      // Final sweep: kill any wl-mirror process the OS is running that
      // doesn't belong to the desired set. Catches orphans left behind
      // by an older `exec wl-mirror` kanshi config or a previous GUI
      // session that crashed before its `dispose` could fire.
      await mirrorRunner.purgeExternalNotMatching(desired);
    } catch (e, st) {
      // `mirrorRunner.start`/`purgeExternalNotMatching` shell out to
      // `pgrep` and `kill`; either can fail if the system is starved
      // for fds, the binaries are missing from PATH, or a pid races
      // with our scan. Logging instead of rethrowing keeps the call
      // sites' fire-and-forget semantics safe under any backend
      // weather, and the `_reconcileChain` outer guard is a separate
      // safety net.
      debugPrint('reconcileMirrors failed: $e\n$st');
    }
  }

  // ── Compositor-driven actions ──────────────────────────────────────────
  Future<OpResult> toggleEnabled(String id, bool enabled) async {
    if (_activeProfileIndex == null) return const OpResult.err('No profile.');
    final mons = _profiles[_activeProfileIndex!].monitors;
    final idx = mons.indexWhere((m) => m.id == id);
    if (idx == -1) return const OpResult.err('Output not found.');

    // Hard-block: refuse if this would leave the user with zero outputs.
    if (!enabled && _wouldLockOutUser(idx)) {
      return const OpResult.err(
          'Cannot disable the last enabled output.');
    }

    final target = _resolveOutputName(id);
    final currentMode = _currentModeForOutput(target);
    if (currentMode == null) {
      return OpResult.err('Output $target not found.');
    }

    try {
      if (!enabled) {
        final r = await monitors.disable(target);
        if (r.exitCode != 0) {
          return OpResult.err(
              'Could not toggle output $target: ${r.stderr}');
        }
      } else {
        final r1 = await monitors.enable(target);
        if (r1.exitCode != 0) {
          return OpResult.err(
              'Could not enable output $target: ${r1.stderr}');
        }
        final r2 = await monitors.apply(mons[idx]);
        if (r2.exitCode != 0) {
          return OpResult.err(
              'Enabled, but failed to set mode: ${r2.stderr}');
        }
      }
    } catch (e) {
      return OpResult.err('Error while toggling: $e');
    }

    await refreshConnectedMonitors();

    final live = _currentMonitors.any((m) =>
        _normalizeOutputId(m.id) == _normalizeOutputId(target) &&
        m.enabled == enabled);
    if (live) {
      _pushHistory(enabled ? 'enable $id' : 'disable $id');
      mons[idx] = mons[idx].copyWith(enabled: enabled);
      _scheduleSave();
      notifyListeners();
      // Guard a *disable* with a SafetyNet — re-enable on timeout.
      if (!enabled) {
        await safetyNet.guard(
          key: 'toggle:$target',
          label: 'Disabled $target',
          doIt: () async {},
          revert: () async {
            await monitors.enable(target);
            await monitors.apply(mons[idx]);
            mons[idx] = mons[idx].copyWith(enabled: true);
            _scheduleSave();
            notifyListeners();
          },
        );
      }
      return OpResult.ok(enabled
          ? 'Output enabled.'
          : 'Output disabled.');
    } else {
      return OpResult.err(
          "Output ${enabled ? 'not enabled' : 'not disabled'} - status unchanged.");
    }
  }

  /// Pushes the current state of [target] (position/scale/transform/mode)
  /// into the running compositor as a single apply call. Used after a
  /// drag/scale/rotate commit so the layout becomes "live" without
  /// requiring an explicit "Save & restart" click. No SafetyNet guard —
  /// the user sees the result immediately and can adjust by hand if it
  /// looks wrong.
  Future<OpResult> pushLiveApply(MonitorTileData target) async {
    if (!monitors.isLive) return const OpResult.ok();
    if (!target.enabled) return const OpResult.ok();
    try {
      final resolved = _resolveOutputName(target.id);
      final r = await monitors.apply(target.copyWith(id: resolved));
      if (r.exitCode != 0) {
        return OpResult.err('Live apply failed: ${r.stderr}');
      }
      return const OpResult.ok();
    } catch (e) {
      return OpResult.err('Live apply error: $e');
    }
  }

  /// True if the active profile would have zero enabled outputs after
  /// disabling the monitor at [idx].
  bool _wouldLockOutUser(int idx) {
    if (_activeProfileIndex == null) return false;
    final mons = _profiles[_activeProfileIndex!].monitors;
    var enabledLeft = 0;
    for (var i = 0; i < mons.length; i++) {
      if (i == idx) continue;
      if (mons[i].enabled) enabledLeft++;
    }
    return enabledLeft == 0;
  }

  Future<OpResult> applyMode(String id, MonitorMode mode) async {
    if (_activeProfileIndex == null) return const OpResult.err('No profile.');
    final mons = _profiles[_activeProfileIndex!].monitors;
    final idx = mons.indexWhere((m) => m.id == id);
    if (idx == -1) return const OpResult.err('Output not found.');
    final target = _resolveOutputName(id);
    final priorMode = MonitorMode(
      width: mons[idx].width,
      height: mons[idx].height,
      refresh: mons[idx].refresh,
    );
    final priorTile = mons[idx];

    if (mons[idx].enabled) {
      try {
        final r = await monitors.setMode(target, mode);
        if (r.exitCode != 0) {
          return OpResult.err('Failed to set mode: ${r.stderr}');
        }
      } catch (e) {
        return OpResult.err('Error setting mode: $e');
      }
      await refreshConnectedMonitors();
    }

    final rotation = mons[idx].rotation;
    final rotW = rotation % 180 == 0 ? mode.width : mode.height;
    final rotH = rotation % 180 == 0 ? mode.height : mode.width;
    _pushHistory(
        "set $id to ${mode.width.toInt()}x${mode.height.toInt()}@${_formatHz(mode.refresh)}");
    mons[idx] = mons[idx].copyWith(
      width: rotW,
      height: rotH,
      refresh: mode.refresh,
      resolution: '${rotW.toInt()}x${rotH.toInt()}',
      orientation: rotation % 180 == 0
          ? (mode.width >= mode.height ? 'landscape' : 'portrait')
          : (mode.width >= mode.height ? 'portrait' : 'landscape'),
    );
    _scheduleSave();
    notifyListeners();

    if (priorTile.enabled) {
      await safetyNet.guard(
        key: 'mode:$target',
        label: 'Mode change on $target',
        doIt: () async {},
        revert: () async {
          // Restore the prior mode at the compositor and in the profile.
          await monitors.setMode(target, priorMode);
          if (_activeProfileIndex != null) {
            final cur = _profiles[_activeProfileIndex!].monitors;
            final i = cur.indexWhere((m) => m.id == priorTile.id);
            if (i != -1) {
              cur[i] = priorTile;
              _scheduleSave();
              notifyListeners();
            }
          }
          await refreshConnectedMonitors();
        },
      );
    }
    return const OpResult.ok();
  }

  Future<OpResult> applyCustomMode(
    String id,
    double w,
    double h,
    double hz, {
    void Function(String, String)? onScheduledRevert,
  }) async {
    final target = _resolveOutputName(id);
    final current = _currentModeForOutput(target);
    if (current != null) {
      _lastModeBeforeCustom[target] = current;
    }
    try {
      final r = await monitors.applyCustomMode(target, w, h, hz);
      if (r.exitCode != 0) {
        return OpResult.err('Custom mode failed: ${r.stderr}');
      }
    } catch (e) {
      return OpResult.err('Custom mode failed: $e');
    }
    await refreshConnectedMonitors();

    if (_activeProfileIndex != null) {
      final mons = _profiles[_activeProfileIndex!].monitors;
      final idx = mons.indexWhere(
          (m) => _normalizeOutputId(m.id) == _normalizeOutputId(target));
      if (idx != -1) {
        _pushHistory(
            "custom mode for $id: ${w.toInt()}x${h.toInt()}@${_formatHz(hz)}");
        final rot = mons[idx].rotation;
        final rotW = rot % 180 == 0 ? w : h;
        final rotH = rot % 180 == 0 ? h : w;
        mons[idx] = mons[idx].copyWith(
          width: rotW,
          height: rotH,
          refresh: hz,
          resolution: '${rotW.toInt()}x${rotH.toInt()}',
          orientation: rot % 180 == 0
              ? (w >= h ? 'landscape' : 'portrait')
              : (w >= h ? 'portrait' : 'landscape'),
        );
        _scheduleSave();
        notifyListeners();
      }
    }
    final label = '${w.toInt()}x${h.toInt()}@${_formatHz(hz)}Hz';
    _revertScheduler.schedule(target, () => revertCustomMode(id));
    onScheduledRevert?.call(target, label);
    return OpResult.ok('Applied custom mode: $label on $target');
  }

  Future<OpResult> revertCustomMode(String id) async {
    final target = _resolveOutputName(id);
    final last = _lastModeBeforeCustom[target];
    if (last == null) {
      return const OpResult.err('No saved custom mode to revert.');
    }
    final r = await applyMode(id, last);
    _lastModeBeforeCustom.remove(target);
    _revertScheduler.cancel(target);
    if (!r.success) return r;
    return const OpResult.ok('Custom mode reverted.');
  }

  void keepCustomMode(String id) {
    _revertScheduler.cancel(_resolveOutputName(id));
  }

  Future<OpResult> enableAllOutputs() async {
    if (_isApplyingBatch) return const OpResult.err('Busy.');
    _isApplyingBatch = true;
    notifyListeners();
    try {
      final outputs = await monitors.getOutputs();
      var ok = 0;
      final failures = <String>[];
      for (final o in outputs) {
        try {
          final r = await monitors.enable(o.id);
          if (r.exitCode != 0) {
            final err = '${r.stderr}'.trim();
            failures.add(
                '${o.manufacturer} (${err.isEmpty ? 'Unknown error' : err})');
          } else {
            ok++;
          }
        } catch (e) {
          failures.add('${o.manufacturer} ($e)');
        }
      }
      await refreshConnectedMonitors();
      await ensureCurrentSetupMatches();
      if (outputs.isEmpty) return const OpResult.ok('No outputs found.');
      if (failures.isEmpty) {
        return OpResult.ok('All ${outputs.length} outputs were enabled successfully.');
      }
      return OpResult.ok(
          'Enabled: $ok/${outputs.length}. Errors: ${failures.join(', ')}');
    } catch (e) {
      return OpResult.err('Failed to enable outputs: $e');
    } finally {
      _isApplyingBatch = false;
      notifyListeners();
    }
  }

  Future<OpResult> reloadAndApply() async {
    try {
      await config.saveProfiles(_profiles);
      final r = await monitors.restartCompositorProfileApply();
      if (r.exitCode != 0) {
        return OpResult.err('kanshi restart failed: ${r.stderr}');
      }
      await refreshConnectedMonitors();
      await _loadConfig();
      return const OpResult.ok('Reloaded and restarted kanshi.');
    } catch (e) {
      return OpResult.err('Reload failed: $e');
    }
  }

  Future<OpResult> reloadOnly() async {
    try {
      await refreshConnectedMonitors();
      await _loadConfig();
      return const OpResult.ok('Outputs and profiles refreshed.');
    } catch (e) {
      return OpResult.err('Reload failed: $e');
    }
  }

  Future<OpResult> saveProfilesOnly() async {
    try {
      await config.saveProfiles(_profiles);
      return const OpResult.ok('Profiles saved.');
    } catch (e) {
      return OpResult.err('Save failed: $e');
    }
  }

  Future<OpResult> restartCompositorService() async {
    try {
      final r = await monitors.restartCompositorProfileApply();
      if (r.exitCode != 0) {
        return OpResult.err('Error: ${r.stderr}');
      }
      return const OpResult.ok('kanshi has been (re)started.');
    } catch (e) {
      return OpResult.err('Exception: $e');
    }
  }

  Future<OpResult> restoreBackupAndApply() async {
    try {
      final backup = await config.newestBackup();
      if (backup == null) {
        return const OpResult.err('No backup found.');
      }
      await backup.copy(config.configPath);
      final r = await reloadAndApply();
      return r.success
          ? const OpResult.ok('Backup restored.')
          : r;
    } catch (e) {
      return OpResult.err('Backup restore failed: $e');
    }
  }

  // ── Helpers exposed for UI ─────────────────────────────────────────────
  MonitorMode? currentModeForOutput(String id) =>
      _currentModeForOutput(_resolveOutputName(id));

  bool monitorIsConnected(MonitorTileData m) =>
      _currentMonitors.any((c) => _matchesOutput(c.id, m.id));

  // ── Internals ──────────────────────────────────────────────────────────
  void _scheduleSave() {
    _saveTimer?.cancel();
    if (_configHasIncludes) {
      // Same rationale as `_flushSaveAndReload`: don't render-and-
      // overwrite a config we only partially parsed.
      onConfigSaveBlocked?.call();
      return;
    }
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      // The save itself runs through ConfigService, which throws
      // `ConfigHasIncludesException` if the user added an include
      // since we last checked. Catch and route to the same UI path.
      // Fire-and-forget by design — a debounced save's errors are
      // best-effort and the next mutation will re-trigger.
      // ignore: discarded_futures
      config.saveProfiles(_profiles).catchError((Object e) {
        if (e is ConfigHasIncludesException) {
          _configHasIncludes = true;
          onConfigSaveBlocked?.call();
        }
      });
    });
  }

  String _normalizeOutputId(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  bool _matchesOutput(String a, String b) =>
      _normalizeOutputId(a) == _normalizeOutputId(b);

  String _resolveOutputName(String idOrManufacturer) {
    final norm = _normalizeOutputId(idOrManufacturer);
    for (final m in _currentMonitors) {
      if (_normalizeOutputId(m.id) == norm ||
          _normalizeOutputId(m.manufacturer) == norm) {
        return m.id;
      }
    }
    return idOrManufacturer;
  }

  /// Score every profile against the currently connected outputs and
  /// return the best non-active fit, but only when it strictly beats
  /// the active profile's own score and clears [confidenceFloor].
  /// Confidence is `matchedScore / max(profileEnabled, currentEnabled)`,
  /// where each match contributes 1.0 for an exact id hit and 0.7 for
  /// a manufacturer-only fallback. Returns `null` when no profile
  /// clears the floor, or when the active profile is already an
  /// equal-or-better fit (the previously-shipped behaviour incorrectly
  /// suggested a 2/3-output profile while the user was on a 3/3-output
  /// active profile, because the active profile's confidence was never
  /// computed at all).
  ProfileSuggestion? findBestProfileSuggestion({
    double confidenceFloor = 0.5,
  }) {
    final currentEnabled =
        _currentMonitors.where((m) => m.enabled).toList();
    if (currentEnabled.isEmpty || _profiles.isEmpty) return null;
    final activeConfidence = _activeProfileIndex == null
        ? 0.0
        : _scoreProfileAgainstCurrent(
            _profiles[_activeProfileIndex!], currentEnabled).confidence;
    ProfileSuggestion? best;
    for (var i = 0; i < _profiles.length; i++) {
      if (i == _activeProfileIndex) continue;
      final scored = _scoreProfileAgainstCurrent(_profiles[i], currentEnabled);
      if (scored.totalOutputs == 0) continue;
      if (best == null || scored.confidence > best.confidence) {
        best = ProfileSuggestion(
          profileIndex: i,
          profileName: _profiles[i].name,
          confidence: scored.confidence,
          matchedOutputs: scored.matched,
          totalOutputs: scored.totalOutputs,
        );
      }
    }
    if (best == null) return null;
    if (best.confidence < confidenceFloor) return null;
    // The active profile already fits at least as well — switching
    // would either be a no-op or a regression. Don't pester the user.
    if (best.confidence <= activeConfidence) return null;
    return best;
  }

  /// Internal helper shared by [findBestProfileSuggestion] and the
  /// active-profile self-score path. Returns the matched-output count,
  /// the normalisation denominator and the resulting confidence.
  _ProfileScore _scoreProfileAgainstCurrent(
    Profile profile,
    List<MonitorTileData> currentEnabled,
  ) {
    final profileEnabled =
        profile.monitors.where((m) => m.enabled).toList();
    if (profileEnabled.isEmpty) {
      return const _ProfileScore(matched: 0, totalOutputs: 0, confidence: 0);
    }
    var score = 0.0;
    var matched = 0;
    final claimed = <int>{};
    for (final pm in profileEnabled) {
      var bestK = -1;
      var bestS = 0.0;
      for (var k = 0; k < currentEnabled.length; k++) {
        if (claimed.contains(k)) continue;
        final cm = currentEnabled[k];
        double s;
        if (_matchesOutput(pm.id, cm.id)) {
          s = 1.0;
        } else if (_matchesOutput(pm.manufacturer, cm.manufacturer)) {
          s = 0.7;
        } else {
          continue;
        }
        if (s > bestS) {
          bestS = s;
          bestK = k;
        }
      }
      if (bestK != -1) {
        claimed.add(bestK);
        score += bestS;
        matched++;
      }
    }
    final denom = profileEnabled.length > currentEnabled.length
        ? profileEnabled.length
        : currentEnabled.length;
    return _ProfileScore(
      matched: matched,
      totalOutputs: denom,
      confidence: score / denom,
    );
  }

  void _maybeFireProfileSuggestion() {
    final cb = onProfileSuggestion;
    if (cb == null) return;
    final since = _lastManualProfileSwitchAt;
    if (since != null &&
        DateTime.now().difference(since) < _suggestionCooldown) {
      return;
    }
    final suggestion = findBestProfileSuggestion();
    if (suggestion == null) return;
    cb(suggestion);
  }

  /// Per-profile match status against the currently connected output
  /// set. The sidebar surfaces this as a coloured dot so the user can
  /// tell at a glance which profiles would auto-fire on dock vs which
  /// are missing outputs.
  ///
  /// Uses two-pass claim tracking (id-exact, then manufacturer
  /// fallback) — the same discipline as [_rehydrateProfilesAgainst]
  /// and [findBestProfileSuggestion]. Without claim tracking, two
  /// physically identical monitors with the same EDID-derived
  /// manufacturer string would both pile onto the same profile slot
  /// and a 1-Samsung profile would falsely look "full" against a
  /// 2-Samsung desk.
  ///
  /// Status semantics:
  ///   - [ProfileMatchStatus.full] — every profile slot is claimed by
  ///     a distinct connected output AND the counts are equal. This
  ///     is the condition the auto-switcher uses to decide whether to
  ///     fire.
  ///   - [ProfileMatchStatus.partial] — at least one profile slot is
  ///     claimed but it isn't a 1-to-1 match (counts differ or some
  ///     slots have no claimant).
  ///   - [ProfileMatchStatus.none] — zero profile slots find a match,
  ///     or the profile / connected set is empty.
  ProfileMatchInfo profileMatchInfo(int index) {
    if (index < 0 || index >= _profiles.length) {
      return const ProfileMatchInfo(
        status: ProfileMatchStatus.none,
        matched: 0,
        profileEnabled: 0,
        currentEnabled: 0,
        missing: [],
      );
    }
    final pEnabled =
        _profiles[index].monitors.where((m) => m.enabled).toList();
    final cEnabled = _currentMonitors.where((m) => m.enabled).toList();
    if (pEnabled.isEmpty || cEnabled.isEmpty) {
      return ProfileMatchInfo(
        status: ProfileMatchStatus.none,
        matched: 0,
        profileEnabled: pEnabled.length,
        currentEnabled: cEnabled.length,
        missing: [for (final m in pEnabled) m.id],
      );
    }
    final claimedCurrent = <int>{};
    final matchedSlots = <int>{};
    // Pass 1: id-exact.
    for (var i = 0; i < pEnabled.length; i++) {
      for (var j = 0; j < cEnabled.length; j++) {
        if (claimedCurrent.contains(j)) continue;
        if (_matchesOutput(pEnabled[i].id, cEnabled[j].id)) {
          claimedCurrent.add(j);
          matchedSlots.add(i);
          break;
        }
      }
    }
    // Pass 2: manufacturer fallback for profile slots still unmatched.
    for (var i = 0; i < pEnabled.length; i++) {
      if (matchedSlots.contains(i)) continue;
      if (pEnabled[i].manufacturer.isEmpty) continue;
      for (var j = 0; j < cEnabled.length; j++) {
        if (claimedCurrent.contains(j)) continue;
        if (cEnabled[j].manufacturer.isEmpty) continue;
        if (_matchesOutput(
            pEnabled[i].manufacturer, cEnabled[j].manufacturer)) {
          claimedCurrent.add(j);
          matchedSlots.add(i);
          break;
        }
      }
    }
    final missing = <String>[
      for (var i = 0; i < pEnabled.length; i++)
        if (!matchedSlots.contains(i)) pEnabled[i].id,
    ];
    final ProfileMatchStatus status;
    if (matchedSlots.length == pEnabled.length &&
        pEnabled.length == cEnabled.length) {
      status = ProfileMatchStatus.full;
    } else if (matchedSlots.isEmpty) {
      status = ProfileMatchStatus.none;
    } else {
      status = ProfileMatchStatus.partial;
    }
    return ProfileMatchInfo(
      status: status,
      matched: matchedSlots.length,
      profileEnabled: pEnabled.length,
      currentEnabled: cEnabled.length,
      missing: missing,
    );
  }

  /// Find a profile whose enabled outputs match the currently
  /// connected set 1-to-1 — i.e. a [ProfileMatchStatus.full] match.
  /// Returns the first such profile in declaration order, or null
  /// when no profile is a complete fit.
  int? _findProfileMatchingCurrent() {
    if (_currentMonitors.where((m) => m.enabled).isEmpty) return null;
    for (var i = 0; i < _profiles.length; i++) {
      if (profileMatchInfo(i).status == ProfileMatchStatus.full) return i;
    }
    return null;
  }

  MonitorMode? _currentModeForOutput(String id) {
    final norm = _normalizeOutputId(id);
    final m =
        _currentMonitors.where((o) => _normalizeOutputId(o.id) == norm).toList();
    if (m.isEmpty) return null;
    return MonitorMode(
      width: m.first.width,
      height: m.first.height,
      refresh: m.first.refresh,
    );
  }

  String _formatHz(double hz) {
    final isInt = (hz - hz.round()).abs() < 0.01;
    return isInt ? hz.round().toString() : hz.toStringAsFixed(3);
  }

  bool wouldExceedBandwidth(List<MonitorTileData> mons) =>
      LayoutMath.totalPixelRate(mons) > 700000000;
}

/// Result of scoring one profile against the live output set. Internal
/// to the controller — promoted to a [ProfileSuggestion] only when the
/// confidence beats the active profile's own score.
class _ProfileScore {
  final int matched;
  final int totalOutputs;
  final double confidence;
  const _ProfileScore({
    required this.matched,
    required this.totalOutputs,
    required this.confidence,
  });
}

/// One profile-match candidate surfaced to the UI when the connected
/// output set fits a non-active profile better than the current one.
/// The controller never auto-switches; the UI typically renders this
/// as a SnackBar with a "Switch" action.
class ProfileSuggestion {
  final int profileIndex;
  final String profileName;
  /// 0..1 confidence — `matchedScore / max(profileEnabled, currentEnabled)`,
  /// where each match contributes 1.0 (exact id) or 0.7 (manufacturer
  /// fallback).
  final double confidence;
  /// How many of the profile's enabled outputs found a match in the
  /// current connected set.
  final int matchedOutputs;
  /// `max(profileEnabled, currentEnabled)` — denominator of [confidence].
  /// Used by the UI to render `"3 of 4 outputs"` style strings.
  final int totalOutputs;
  const ProfileSuggestion({
    required this.profileIndex,
    required this.profileName,
    required this.confidence,
    required this.matchedOutputs,
    required this.totalOutputs,
  });
}

/// At-a-glance compatibility of a saved profile with the currently
/// connected output set, surfaced as a coloured dot in the sidebar.
enum ProfileMatchStatus {
  /// Every profile slot has a distinct connected output AND the
  /// counts are equal — auto-switch would fire on this profile.
  full,
  /// At least one profile slot is matched but the fit isn't 1-to-1
  /// (counts differ or some slots have no claimant).
  partial,
  /// Zero profile slots find a match (or the profile / connected set
  /// is empty).
  none,
}

/// Result of [KanshiController.profileMatchInfo]. The sidebar uses
/// [status] for the dot colour and the rest of the fields to compose
/// a tooltip like "2 of 3 outputs connected — DP-2 missing".
class ProfileMatchInfo {
  final ProfileMatchStatus status;
  /// How many profile slots claimed a connected output.
  final int matched;
  /// Number of enabled monitors in the profile.
  final int profileEnabled;
  /// Number of enabled monitors currently connected.
  final int currentEnabled;
  /// Output ids from the profile that have no claimant in the
  /// current connected set (i.e. what's "missing" from the user's
  /// physical desk to make this profile a full match).
  final List<String> missing;
  const ProfileMatchInfo({
    required this.status,
    required this.matched,
    required this.profileEnabled,
    required this.currentEnabled,
    required this.missing,
  });
}

class _HistoryEntry {
  final List<Profile> profiles;
  final int? activeIndex;
  final String label;
  const _HistoryEntry({
    required this.profiles,
    required this.activeIndex,
    required this.label,
  });
}

/// Per-drag bookkeeping for the alignment-escape heuristic. Keeps track of
/// the previous frame's alignment state so the controller can detect when
/// the user has "broken out" of an alignment snap, and counts those breakouts
/// per axis. After [_alignmentEscapeLimit] escapes the alignment magnet on
/// that axis stays off until the next [beginDragSession] call. Also carries
/// the pre-drag tile snapshot so that an externally-driven cancellation
/// (hotplug, profile switch) can roll the profile back to where it started
/// — `updateMonitor` writes mid-drag positions into the profile that we'd
/// otherwise commit by accident.
class _DragSession {
  bool lastYAlignmentApplied = false;
  bool lastXAlignmentApplied = false;
  int yEscapeCount = 0;
  int xEscapeCount = 0;
  MonitorTileData? rollbackOrigin;
}
