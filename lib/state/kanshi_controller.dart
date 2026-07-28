import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/domain/output_matcher.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';
import 'package:kanshi_gui/services/kanshi_daemon.dart';
import 'package:kanshi_gui/services/layout_math.dart';
import 'package:kanshi_gui/services/mirror_runner.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/process_runner.dart';
import 'package:kanshi_gui/state/app_status.dart';
import 'package:kanshi_gui/state/history_stack.dart';
import 'package:kanshi_gui/state/live_outputs.dart';
import 'package:kanshi_gui/state/custom_mode_revert_scheduler.dart';
import 'package:kanshi_gui/state/drag_sessions.dart';
import 'package:kanshi_gui/state/drift_monitor.dart';
import 'package:kanshi_gui/state/safety_net.dart';
import 'package:kanshi_gui/state/save_coordinator.dart';
import 'package:kanshi_gui/state/workspace_placement.dart';

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
  ///
  /// Mutable at runtime via [setSnapDistance] (settings UI). Stored
  /// privately; widgets read it through the [snapThreshold] getter and
  /// rebuild on the change's `notifyListeners`.
  double _snapThreshold;
  double get snapThreshold => _snapThreshold;

  List<Profile> _profiles = [];
  final DriftMonitor _drift = DriftMonitor();
  late final DragSessions _drags = DragSessions()
    ..onChanged = notifyListeners;
  late final LiveOutputs _live = LiveOutputs(monitors);
  late final WorkspacePlacement _workspaces = WorkspacePlacement(monitors);

  /// The connected hardware, owned by [LiveOutputs]. Read-only here on
  /// purpose: this used to be assignable from four places, which is how the
  /// auto-created setup ended up aliasing it and blinding drift detection.
  List<MonitorTileData> get _currentMonitors => _live.current;
  int? _activeProfileIndex;
  bool _isApplyingBatch = false;
  /// True when the active layout has edits that haven't been pushed to the
  /// compositor via an explicit Apply yet. Set whenever a mutation schedules
  /// a save, cleared on a successful [reloadAndApply]. Drives the header's
  /// "unapplied changes" dot + Apply button.
  bool _hasUnappliedEdits = false;
  late final SaveCoordinator _saves = _buildSaveCoordinator();

  SaveCoordinator _buildSaveCoordinator() {
    final s = SaveCoordinator(config);
    s.onBlocked = (reason) => onConfigSaveBlocked?.call(reason);
    s.onChanged = () {
      if (!_isDisposed) notifyListeners();
    };
    return s;
  }
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
  bool get configHasIncludes => _saves.hasIncludes;

  /// Whether a kanshi daemon was seen running. Null until probed.
  bool? _kanshiRunning;
  bool? get kanshiRunning => _kanshiRunning;

  /// Re-probes whether kanshi is running. Cheap, and the answer decides
  /// whether the app may promise that the layout comes back after a reboot.
  Future<void> refreshKanshiRunning() async {
    _kanshiRunning = await KanshiDaemon(_processRunner).isRunning();
    if (!_isDisposed) notifyListeners();
  }

  /// How much of "these screens will come back exactly like this" the app has
  /// actually earned right now.
  ///
  /// Deliberately conservative: every gate that cannot be checked downgrades
  /// the sentence. The green check must never be a decoration.
  AssuranceLevel get assuranceLevel {
    if (_saves.lastSaveOk == false) return AssuranceLevel.written;
    if (saveBlockedReason != null) return AssuranceLevel.written;
    if (_saves.lastSaveOk == null && _profiles.isEmpty) {
      return AssuranceLevel.unknown;
    }
    // No live backend: the file is all we can speak for.
    if (!monitors.isLive) return AssuranceLevel.writtenOnly;
    // Something else is driving the screens away from what we saved.
    if (hasLayoutDrift) return AssuranceLevel.written;
    // Nothing will re-apply the file at boot.
    if (_kanshiRunning == false) return AssuranceLevel.written;
    return AssuranceLevel.verified;
  }

  /// Why saving is currently refused, or null when it is not.
  String? get saveBlockedReason => _saves.blockedReason;

  final Map<String, MonitorMode> _lastModeBeforeCustom = {};

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
  /// Fired when a save was attempted but refused, with the reason. Two
  /// things can refuse: the config uses `include` directives (saving would
  /// orphan profiles in the included files), or it contains syntax the
  /// parser did not model (saving would delete it). The HomePage surfaces
  /// this as a persistent SnackBar so the user knows why their changes are
  /// not landing on disk — a silent refusal would be worse than the data
  /// loss it prevents.
  void Function(String reason)? onConfigSaveBlocked;
  /// Fired when a safety-net revert threw. This is the worst moment the app
  /// has: the risky change is still in effect — the user may be looking at
  /// a black screen — and the automatic way out just failed. It must be
  /// surfaced with a retry, never swallowed. [retrySafetyNetReverts] runs
  /// the failed inverses again.
  void Function(String label, Object error)? onSafetyNetRevertFailed;
  /// Wallclock of the last manual profile switch. Auto-suggestions are
  /// suppressed for [_suggestionCooldown] after this so a user who just
  /// picked profile A on purpose doesn't get nagged into switching back.
  DateTime? _lastManualProfileSwitchAt;
  static const Duration _suggestionCooldown = Duration(seconds: 30);

  /// Undo/redo history. Each entry is a deep snapshot of `_profiles` and
  /// the active index taken just before a mutation. The stacks are LIFO;
  /// pushing onto undo clears redo, undoing pops onto redo, redoing pops
  /// onto undo. Capped at [_historyCap] entries to keep memory bounded.
  final HistoryStack _history = HistoryStack();
  Map<String, int> _identifyNumbers = const {};
  Timer? _identifyTimer;
  final List<ProcessStream> _identifyBanners = [];
  /// Monotonically increasing token bumped whenever in-flight drag state
  /// is invalidated (hotplug clearing sessions, profile switch, etc.).
  /// Tiles snapshot this on `beginDragSession` and treat any later
  /// `onPanUpdate` / `onPanEnd` whose snapshot doesn't match the current
  /// epoch as stale — they snap back instead of writing into a session
  /// the controller has already torn down.

  /// Scale values the slider rasters onto on release. Chosen for real-world
  /// HiDPI scenarios; intentionally excludes integer scales > 3 because
  /// they are essentially never useful and would create the "I can't get
  /// off 1.0" trap if every integer were a magnet.

  /// User opt-in for the Sway workspace distribution. `null` means the
  /// feature is off; a non-null value also picks how workspaces are spread
  /// (see [WorkspaceDistribution]). Held here so [_effectiveWriteOptions]
  /// can gate the backend's capability default on the user's choice, and so
  /// [setWorkspaceDistribution] can flip it at runtime.
  WorkspaceDistribution? _workspaceDistribution;

  /// Whether scale-slider release rasters onto the common HiDPI snap
  /// values. Mutable via [setScaleSnapping] (settings UI).
  bool scaleSnapping = true;

  /// Whether an explicit Apply arms the auto-revert countdown. Off by
  /// default — routine applies shouldn't nag; opt in for the safety net.
  bool autoRevertOnApply = false;

  /// When true (default), edits push to the compositor immediately and the
  /// UI hides the Apply button. When false, edits are staged until Apply.
  bool liveApply = true;

  /// When true, the hotplug listener fires `kanshictl reload` automatically
  /// if the live output positions don't match the active profile after a
  /// hotplug. Off by default — the drift banner gives the user a one-click
  /// re-apply; this flag removes the click.
  bool autoReapplyOnDrift = false;

  /// True after the user explicitly dismissed the drift banner so it does
  /// not nag again until the next hotplug clears it.

  /// Debounce timer for the auto-reapply path. Cleared on every hotplug;
  /// the body re-checks `hasLayoutDrift` at fire time so a drift that
  /// resolved itself in the meantime doesn't trigger a redundant reload.
  Timer? _driftAutoReapplyTimer;
  Timer? _liveApplyRefreshTimer;
  /// Settle window after a [pushLiveApply] before we re-read Sway's outputs.
  /// Sway can silently auto-arrange around the just-applied output (e.g.
  /// shift a sibling rightwards to resolve an overlap), so we wait briefly
  /// and then refresh `_currentMonitors` — that in turn recomputes drift
  /// and surfaces the banner if the live layout no longer matches the
  /// profile. Tests override this with [Duration.zero].
  Duration postLiveApplyDelay = const Duration(milliseconds: 200);

  /// How long the identify-display number banners stay on screen.
  Duration identifyBannerDuration = const Duration(seconds: 3);

  /// wl-mirror `--scaling` mode, folded into the effective write options
  /// (boot-fallback exec line) and pushed to the live [mirrorRunner].
  String _mirrorScaling = 'fit';

  final ProcessRunner _processRunner;

  KanshiController({
    required this.monitors,
    required this.config,
    MirrorRunner? mirrorRunner,
    double snapThreshold = 60.0,
    WorkspaceDistribution? workspaceDistribution,
    ProcessRunner? processRunner,
  })  : mirrorRunner = mirrorRunner ?? MirrorRunner(),
        _snapThreshold = snapThreshold,
        _workspaceDistribution = workspaceDistribution,
        _processRunner = processRunner ?? const DefaultProcessRunner() {
    config.writeOptions = _effectiveWriteOptions();
    safetyNet.onChange((prompt) {
      _syncSafetyPrompts(prompt);
      notifyListeners();
    });
    safetyNet.onRevertFailed = (key, label, error) {
      debugPrint('safety-net revert failed for $key: $error');
      onSafetyNetRevertFailed?.call(label, error);
    };
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
  int get dragCancelEpoch => _drags.cancelEpoch;
  List<Profile> get profiles => List.unmodifiable(_profiles);
  List<MonitorTileData> get currentMonitors =>
      List.unmodifiable(_currentMonitors);
  int? get activeProfileIndex => _activeProfileIndex;
  Profile? get activeProfile =>
      _activeProfileIndex == null ? null : _profiles[_activeProfileIndex!];
  List<MonitorTileData> get activeMonitors =>
      activeProfile?.monitors ?? const [];
  bool get isApplyingBatch => _isApplyingBatch;
  /// True only in staged (non-live) mode. With live apply on, every edit is
  /// pushed immediately, so there is by definition nothing "unapplied".
  bool get hasUnappliedEdits => !liveApply && _hasUnappliedEdits;
  bool get supportsLiveApply => monitors.isLive;
  /// True when there's a snapshot to roll back to via [undo].
  bool get canUndo => _history.canUndo;
  /// True when [redo] has a snapshot to replay.
  bool get canRedo => _history.canRedo;
  /// Human-readable label of the most recent undoable mutation, or null
  /// when the stack is empty. Used by the UI for tooltips like
  /// "Undo: toggle DP-1".
  String? get nextUndoLabel => _history.nextUndoLabel;
  String? get nextRedoLabel => _history.nextRedoLabel;
  bool get supportsMirror => monitors.supportsMirror;
  List<SnapLine> get activeSnapLines => _drags.activeSnapLines;

  /// Backend capability: can this compositor distribute workspaces via the
  /// Sway exec chain at all? True only for the Sway backend (wlr-randr /
  /// niri / noop emit a neutral config with no workspace exec). Independent
  /// of the user's opt-in — the UI uses this to decide whether to even
  /// surface the workspace-management control.
  bool get supportsWorkspaceManagement =>
      monitors.writeOptions.injectSwayWorkspaceExec;

  /// The active workspace distribution, or null when management is off.
  WorkspaceDistribution? get workspaceDistribution => _workspaceDistribution;

  /// Effective write options: the backend's capability defaults, with the
  /// Sway workspace exec gated on the user's opt-in (and forced off entirely
  /// on backends that can't do it). Keeping this in one place means the
  /// rendered kanshi config and the controller's runtime apply path always
  /// agree on whether — and how — to distribute workspaces.
  KanshiWriteOptions _effectiveWriteOptions() {
    final base = monitors.writeOptions.copyWith(mirrorScaling: _mirrorScaling);
    final dist = _workspaceDistribution;
    if (!supportsWorkspaceManagement || dist == null) {
      return base.copyWith(injectSwayWorkspaceExec: false);
    }
    return base.copyWith(
      injectSwayWorkspaceExec: true,
      workspaceDistribution: dist,
    );
  }

  /// Bounding box (in absolute monitor space) the canvas should pin its
  /// projection to. Non-null only while a drag session is active. Without
  /// this, dragging a monitor into negative coordinates (e.g. above origin)
  /// would shift `minX`/`minY` every frame, causing the entire layout —
  /// including non-dragged tiles — to reflow under the cursor and produce
  /// "duplicate" / overlapping ghost imprints.
  Rect? get pinnedLayoutBounds => _drags.pinnedBounds;
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

    _identifyTimer = Timer(identifyBannerDuration, () {
      _identifyNumbers = const {};
      _killIdentifyBanners();
      notifyListeners();
    });
    notifyListeners();
  }

  /// Per-output prompts shown while a risky change is on trial.
  final List<ProcessStream> _safetyPrompts = [];

  /// Mirrors the armed guard onto every connected output.
  ///
  /// The in-window countdown is not enough on its own: the window may be
  /// sitting on the screen the change just blacked out, in which case the
  /// user sees nothing at all and simply waits for the revert without knowing
  /// one is coming. A prompt on every output means the message survives its
  /// own worst case.
  void _syncSafetyPrompts(SafetyNetPrompt? prompt) {
    if (prompt == null) {
      _killSafetyPrompts();
      return;
    }
    if (_safetyPrompts.isNotEmpty) return; // already showing for this guard
    if (!monitors.isLive) return;
    final seconds = safetyNet.window.inSeconds;
    final message = 'Can you read this? ${prompt.label}. '
        'It undoes itself in ${seconds}s unless you keep it in kanshi_gui.';
    for (final m in _currentMonitors.where((m) => m.enabled)) {
      try {
        final stream = monitors.spawnSafetyPrompt(m.id, message);
        if (stream != null) _safetyPrompts.add(stream);
      } catch (e) {
        debugPrint('safety prompt on ${m.id} failed: $e');
      }
    }
  }

  void _killSafetyPrompts() {
    for (final s in _safetyPrompts) {
      try {
        s.kill();
      } catch (_) {/* best effort */}
    }
    _safetyPrompts.clear();
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
    // Learn the shape of the live config before anything can schedule a
    // save, so a refusal is known up front rather than after the user's
    // first edit silently fails to land.
    await _saves.inspect();
    // persist: false — opening the app must never rewrite (and risk
    // re-applying) the user's working config. See [ensureCurrentSetupMatches].
    await ensureCurrentSetupMatches(persist: false);
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
    // The status line may only promise the layout comes back if something
    // will actually re-apply it at boot.
    await refreshKanshiRunning();
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
    final activeIdx = _activeProfileIndex;
    if (activeIdx == null) return;
    await _workspaces.verifyAndFix(
      // The effective option, not the backend's raw capability: when the user
      // has workspace management off we must not touch the live layout.
      enabled: config.writeOptions.injectSwayWorkspaceExec,
      profileMonitors: _profiles[activeIdx].monitors,
      liveOutputs: _currentMonitors,
      distribution: config.writeOptions.workspaceDistribution,
      resolveConnector: _resolveOutputName,
      force: force,
      isCancelled: () => _isDisposed,
    );
  }

  /// How long the output set must stay unchanged before the hotplug pipeline
  /// re-runs against it.
  ///
  /// Docking does not produce one event, it produces a salvo: outputs appear
  /// one at a time as the dock enumerates them, and EDID can settle late.
  /// Every one of those events used to run the full pipeline — rehydrate,
  /// auto-switch, mirror reconcile, drift — against a half-connected set.
  ///
  /// The barrier is leading-edge WITH a trailing re-run: the first event is
  /// handled at once so screens appear immediately, further events inside the
  /// window are coalesced, and once the set holds still the pipeline runs once
  /// more against the complete set. Responsiveness is kept; the final state is
  /// computed from the whole picture.
  /// Forwarded to [LiveOutputs.settleWindow]; see there for why a dock salvo
  /// must not run the pipeline once per event.
  Duration get hotplugSettleWindow => _live.settleWindow;
  set hotplugSettleWindow(Duration v) => _live.settleWindow = v;

  void _subscribeHotplug() {
    _live.subscribe((change) {
      if (_isDisposed) return;
      _handleOutputsChanged(change);
    });
  }

  void _handleOutputsChanged(OutputsChanged change) {
    {
      final newOutputs = change.outputs;
      // Cancelling the subscription does NOT abort an in-flight handler;
      // the body must self-guard so a hotplug event delivered between
      // `dispose()` setting the flag and the runtime tearing the
      // listener down can't drive `notifyListeners` on a disposed
      // controller (debug assertion) or fire callbacks against widgets
      // that have already detached.
      if (_isDisposed) return;
      final added = change.added;
      final removed = change.removed;
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
      // A fresh hotplug invalidates any prior dismissal of the drift
      // banner — the new live layout might genuinely diverge from the
      // active profile (the kanshi-daemon position-drop race) and the
      // user deserves another chance to see/repair it.
      _drift.resetDismissal();
      _recomputeDriftIssues();
      notifyListeners();
      _scheduleDriftAutoReapply();
      for (final id in added) {
        onHotplugToast?.call('$id connected');
      }
      for (final id in removed) {
        onHotplugToast?.call('$id disconnected');
      }
    }
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
    _saves.dispose();
    _driftAutoReapplyTimer?.cancel();
    _liveApplyRefreshTimer?.cancel();
    _revertScheduler.cancelAll();
    safetyNet.cancelAll();
    _live.dispose();
    _identifyTimer?.cancel();
    _killIdentifyBanners();
    _killSafetyPrompts();
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
    if (!await _live.refresh()) return;
    _rehydrateProfilesAgainst(_currentMonitors);
    _recomputeDriftIssues();
    notifyListeners();
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
    // The pass ordering lives in OutputMatcher.pair: descriptor, then
    // connector, then label, with each pass blind to what earlier passes
    // claimed. Running descriptor first is what lets a profile find its
    // monitor again after a reboot renumbered the ports.
    for (final profile in _profiles) {
      final pairs = OutputMatcher.pair(profile.monitors, live);
      pairs.forEach((entryIdx, liveIdx) {
        final pe = profile.monitors[entryIdx];
        final l = live[liveIdx];
        profile.monitors[entryIdx] = pe.copyWith(
          id: l.id,
          manufacturer: l.manufacturer,
          // Record the stable identity the moment we observe it. This is the
          // whole migration path for existing configs: nothing is ever
          // guessed from the stored label — which drops "Unknown" and so
          // would produce criteria kanshi never matches — only what a live
          // backend actually reported gets written back.
          edidDescriptor:
              l.edidDescriptor.isNotEmpty ? l.edidDescriptor : pe.edidDescriptor,
          refresh: l.refresh,
          modes: l.modes,
        );
      });
    }
  }

  /// Reconciles the active profile against the live outputs, creating a
  /// throwaway "Current Setup" when nothing matches. [persist] controls
  /// whether the resulting config is written to disk — it defaults to true
  /// for explicit callers, but [init] passes false: on launch we must NOT
  /// overwrite (and thereby risk re-applying) the user's working kanshi
  /// config when they haven't changed anything. The captured setup lives in
  /// memory and is persisted the moment the user makes a real edit.
  Future<void> ensureCurrentSetupMatches({bool persist = true}) async {
    final matchIdx = _findProfileMatchingCurrent();
    if (matchIdx != null) {
      _activeProfileIndex = matchIdx;
    } else {
      const currentName = 'Current Setup';
      // COPY the live list. Handing `_currentMonitors` itself to the profile
      // aliased the compositor snapshot into the editor: every drag wrote
      // through the profile into what the app believed the compositor was
      // doing, so drift detection compared the live layout against itself
      // and could never report anything.
      final snapshot = List<MonitorTileData>.from(_currentMonitors);
      final idx = _profiles.indexWhere((p) => p.name == currentName);
      if (idx == -1) {
        _profiles.add(Profile(name: currentName, monitors: snapshot));
        _activeProfileIndex = _profiles.length - 1;
      } else {
        _profiles[idx] = Profile(name: currentName, monitors: snapshot);
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
    if (persist) _scheduleSave();
    _recomputeDriftIssues();
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
  }) =>
      _history.push(_profiles, _activeProfileIndex, label,
          overrides: overrides);

  /// Reverts the most recent mutation by replacing `_profiles` and the
  /// active index with the top of the undo stack, pushing the current
  /// state onto the redo stack so it can be replayed via [redo].
  /// Schedules a save and reload so the compositor catches up.
  Future<OpResult> undo() async {
    final entry = _history.undo(_currentSnapshot(''));
    if (entry == null) return const OpResult.err('Nothing to undo.');
    await _restoreSnapshot(entry);
    return OpResult.ok('Undone: ${entry.label}');
  }

  Future<OpResult> redo() async {
    final entry = _history.redo(_currentSnapshot(''));
    if (entry == null) return const OpResult.err('Nothing to redo.');
    await _restoreSnapshot(entry);
    return OpResult.ok('Redone: ${entry.label}');
  }

  HistoryEntry _currentSnapshot(String label) =>
      HistoryStack.snapshot(_profiles, _activeProfileIndex, label);

  Future<void> _restoreSnapshot(HistoryEntry entry) async {
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
    await _saves.flush(_profiles);
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

  /// Rejects names that cannot survive a round trip through the kanshi
  /// config. Returns null when [name] is acceptable, otherwise the reason.
  ///
  /// The writer used to interpolate the name straight into
  /// `profile '<name>' {`, so an empty name produced `profile '' {` and a
  /// name containing a newline or a brace produced a file kanshi refuses to
  /// parse — at which point the daemon stops managing displays entirely and
  /// the GUI cannot read its own profiles back. Apostrophes and backslashes
  /// are not rejected: they are escaped by the writer and unescaped by the
  /// parser, because "Nico's Desk" is a name a person would reasonably type.
  static String? profileNameError(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Profile name cannot be empty.';
    if (trimmed.length > 120) return 'Profile name is too long.';
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(trimmed)) {
      return 'Profile name cannot contain line breaks or control characters.';
    }
    if (trimmed.contains('{') || trimmed.contains('}')) {
      return 'Profile name cannot contain { or }.';
    }
    if (trimmed.startsWith('#')) {
      return 'Profile name cannot start with #.';
    }
    return null;
  }

  OpResult renameProfile(int index, String newName) {
    if (index < 0 || index >= _profiles.length) {
      return const OpResult.err('Profile index out of range.');
    }
    final invalid = profileNameError(newName);
    if (invalid != null) return OpResult.err(invalid);
    newName = newName.trim();
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
    // Only enabled, non-mirrored monitors are real snap / overlap
    // targets — disabled tiles and mirror tiles are rendered parked
    // beside the active cluster, not at their stored coordinates, so
    // snapping or overlap-checking against their raw position would
    // offer phantom targets the user cannot see.
    final activeOnly =
        mons.where((m) => m.enabled && m.mirrorOf == null).toList();
    final activeIdx = activeOnly.indexWhere((m) => m.id == dragged.id);
    final result = _drags.commitSnap(mons[idx], activeOnly, snapThreshold);
    mons[idx] = result.tile;
    activeOnly[activeIdx] = result.tile;
    if (LayoutMath.hasOverlap(result.tile, activeOnly, activeIdx) &&
        rollbackTo != null) {
      mons[idx] = rollbackTo;
    }
    _profiles[_activeProfileIndex!] =
        Profile(name: _profiles[_activeProfileIndex!].name, monitors: mons);
    _drags.clearPreview();
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
    // Pin against the truly-independent active cluster only — mirror tiles
    // and disabled ones are parked, so a bounding box that included them
    // would freeze the canvas around phantom positions.
    final cluster = _activeProfileIndex == null
        ? const <MonitorTileData>[]
        : _profiles[_activeProfileIndex!]
            .monitors
            .where((m) => m.enabled && m.mirrorOf == null)
            .toList();
    return _drags.begin(id, rollback, cluster);
  }

  /// Cancel every in-flight drag session: roll the profile back to each
  /// session's pre-drag snapshot, drop the alignment-escape state, free
  /// the pinned bounding box, and bump the cancel-epoch so any tile
  /// mid-gesture detects the invalidation and snaps back. No-op when
  /// there are no active sessions and no pinned bounds.
  void _cancelInFlightDrags() {
    final rollbacks = _drags.cancelAll();
    if (rollbacks.isEmpty || _activeProfileIndex == null) return;
    final mons = [..._profiles[_activeProfileIndex!].monitors];
    var dirty = false;
    rollbacks.forEach((id, origin) {
      final idx = mons.indexWhere((m) => m.id == id);
      if (idx == -1) return;
      mons[idx] = origin;
      dirty = true;
    });
    if (dirty) {
      _profiles[_activeProfileIndex!] = Profile(
        name: _profiles[_activeProfileIndex!].name,
        monitors: mons,
      );
    }
  }

  /// UI calls this when the drag ends (mouse up). Clears the session so the
  /// next grab is fresh and releases the layout pin so the canvas reflows
  /// to the post-drag state.
  void endDragSession(String id) => _drags.end(id);

  /// Computes the snap result for [dragged] without mutating any state and
  /// publishes the active snap lines so the UI can render guide lines while
  /// the drag is in progress. Tracks alignment-escape: if the user pulls
  /// the tile out of an active alignment snap twice within the same drag
  /// session, that axis's alignment magnet stays off until the next grab.
  void previewSnap(MonitorTileData dragged) {
    if (_activeProfileIndex == null) {
      _drags.clearPreview();
      return;
    }
    _drags.previewSnap(
      dragged,
      _profiles[_activeProfileIndex!]
          .monitors
          .where((m) => m.enabled && m.mirrorOf == null)
          .toList(),
      snapThreshold,
    );
  }

  void clearSnapPreview() => _drags.clearPreview();

  double _maybeSnapScale(String id, double raw) =>
      _drags.snapScale(id, raw, enabled: scaleSnapping);

  Future<void> rearrangeActiveLayout() async {
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
    await _applyActiveProfileLive();
  }

  // ── Health checks ──────────────────────────────────────────────────────

  /// Best-effort environment sanity checks surfaced as a dismissible banner
  /// on launch. Returns a list of human-readable warnings (empty = all
  /// good). Never throws — a probe that itself fails is simply skipped.
  Future<List<String>> checkHealth() async {
    final warnings = <String>[];
    if (!monitors.isLive) {
      warnings.add(
          'No Wayland output tool (swaymsg/wlr-randr) detected — running as '
          'an offline profile editor. Changes won\'t reach a compositor.');
      return warnings;
    }
    // kanshi present?
    try {
      if (!await _processRunner.exists('kanshi')) {
        warnings.add(
            'kanshi is not installed — saved profiles won\'t be applied '
            'automatically. Install kanshi to get auto-switching.');
      } else {
        // kanshi running? (pgrep may be absent; treat probe failure as
        // "unknown" and stay quiet rather than cry wolf.)
        try {
          final r = await _processRunner.run('pgrep', ['-x', 'kanshi']);
          if (r.exitCode == 1) {
            warnings.add(
                'kanshi doesn\'t appear to be running — start it (e.g. via '
                'your sway config or its systemd service) so profiles apply.');
          }
        } catch (_) {/* pgrep missing — skip */}
      }
    } catch (_) {/* exists() failure — skip */}
    // wl-mirror needed for the mirror UX on Sway.
    if (monitors.supportsMirror) {
      try {
        if (!await mirrorRunner.isAvailable()) {
          warnings.add(
              'wl-mirror is not installed — monitor mirroring is unavailable.');
        }
      } catch (_) {/* skip */}
    }
    return warnings;
  }

  // ── Quick-layout presets ───────────────────────────────────────────────
  // All presets mutate the active profile in memory (overlap-safe) and
  // schedule a save; nothing reaches the compositor until the user hits
  // Apply, so a preset is a previewable suggestion, not a surprise.

  /// Lay every enabled output side-by-side, left-to-right, flush at y=0, and
  /// drop any mirroring — the classic "extend my desktop across all screens".

  /// Pushes the active profile's layout into the running compositor.
  ///
  /// The quick-layout presets and the rearrange action used to mutate the
  /// profile and call [_scheduleSave] only — and unlike [_flushSaveAndReload],
  /// _scheduleSave never asks kanshi to re-apply. So the tiles jumped, a green
  /// "Extended across all outputs." toast appeared, and the physical screens
  /// did not move until the next hotplug or reload. The one hint that could
  /// have explained it is suppressed in the default configuration, because
  /// `hasUnappliedEdits` is `!liveApply && _hasUnappliedEdits` and liveApply
  /// defaults to true.
  ///
  /// Best-effort by design: a failure is reported to the caller so it can say
  /// so, rather than being swallowed behind a success toast.
  Future<String?> _applyActiveProfileLive() async {
    if (!liveApply || !monitors.isLive) return null;
    final idx = _activeProfileIndex;
    if (idx == null) return null;
    final failures = <String>[];
    for (final m in List.of(_profiles[idx].monitors)) {
      final target = _resolveOutputName(m.id);
      if (!_currentMonitors.any((c) => _matchesOutput(c.id, target))) continue;
      try {
        final r = m.enabled
            ? await monitors.apply(m.copyWith(id: target))
            : await monitors.disable(target);
        if (r.exitCode != 0) {
          failures.add('$target: ${r.stderr.toString().trim()}');
        }
      } catch (e) {
        failures.add('$target: $e');
      }
      if (_isDisposed) return null;
    }
    if (failures.isEmpty) return null;
    return failures.join('; ');
  }

  Future<OpResult> extendOutputs() async {
    final idx = _activeProfileIndex;
    if (idx == null) return const OpResult.err('No active profile.');
    final profile = _profiles[idx];
    final enabled = profile.monitors.where((m) => m.enabled).toList()
      ..sort((a, b) {
        final byX = a.x.compareTo(b.x);
        return byX != 0 ? byX : a.id.compareTo(b.id);
      });
    if (enabled.isEmpty) return const OpResult.err('No enabled output.');
    _pushHistory('extend outputs');
    final placed = <String, MonitorTileData>{};
    var cursorX = 0.0;
    for (final m in enabled) {
      placed[m.id] = m.copyWith(x: cursorX, y: 0, mirrorOf: null);
      cursorX += m.width / (m.scale == 0 ? 1.0 : m.scale);
    }
    _profiles[idx] = Profile(
      name: profile.name,
      monitors: [for (final m in profile.monitors) placed[m.id] ?? m],
    );
    _scheduleSave();
    notifyListeners();
    final failed = await _applyActiveProfileLive();
    if (failed != null) {
      return OpResult.err('Saved, but the compositor refused part of it: $failed');
    }
    return const OpResult.ok('Extended across all outputs.');
  }

  /// Mirror every other enabled output onto the leftmost one (the primary).
  /// Sway-only — wl-mirror drives the actual duplication on apply/reconcile.
  Future<OpResult> mirrorAll() async {
    if (!supportsMirror) {
      return const OpResult.err('Mirroring needs the Sway backend.');
    }
    final idx = _activeProfileIndex;
    if (idx == null) return const OpResult.err('No active profile.');
    final profile = _profiles[idx];
    final enabled = profile.monitors.where((m) => m.enabled).toList()
      ..sort((a, b) {
        final byX = a.x.compareTo(b.x);
        return byX != 0 ? byX : a.id.compareTo(b.id);
      });
    if (enabled.length < 2) {
      return const OpResult.err('Need at least two enabled outputs to mirror.');
    }
    final primary = enabled.first.id;
    _pushHistory('mirror all onto $primary');
    final updated = <String, MonitorTileData>{};
    for (final m in enabled) {
      updated[m.id] =
          m.copyWith(mirrorOf: m.id == primary ? null : primary);
    }
    _profiles[idx] = Profile(
      name: profile.name,
      monitors: [for (final m in profile.monitors) updated[m.id] ?? m],
    );
    _scheduleSave();
    notifyListeners();
    await _reconcileMirrors();
    final failed = await _applyActiveProfileLive();
    if (failed != null) {
      return OpResult.err('Saved, but the compositor refused part of it: $failed');
    }
    return OpResult.ok('Mirroring all outputs onto $primary.');
  }

  /// Enable only [keepId] and disable every other output — "laptop only" /
  /// "external only". Clears mirroring on the kept output. Refuses if
  /// [keepId] isn't a known output (would otherwise black everything out).
  Future<OpResult> useOnlyOutput(String keepId) async {
    final idx = _activeProfileIndex;
    if (idx == null) return const OpResult.err('No active profile.');
    final profile = _profiles[idx];
    if (!profile.monitors.any((m) => m.id == keepId)) {
      return OpResult.err('$keepId not in the active profile.');
    }
    _pushHistory('use only $keepId');
    _profiles[idx] = Profile(
      name: profile.name,
      monitors: [
        for (final m in profile.monitors)
          m.id == keepId
              ? m.copyWith(enabled: true, mirrorOf: null, x: 0, y: 0)
              : m.copyWith(enabled: false, mirrorOf: null),
      ],
    );
    _scheduleSave();
    notifyListeners();
    await _reconcileMirrors();
    final failed = await _applyActiveProfileLive();
    if (failed != null) {
      return OpResult.err('Saved, but the compositor refused part of it: $failed');
    }
    return OpResult.ok('Using only $keepId.');
  }

  // ── Settings application ───────────────────────────────────────────────

  /// Pushes the controller-backed preferences from [s] into the live
  /// objects. Called once at startup *before* [init] so the first config
  /// save already reflects them — it deliberately does NOT trigger a
  /// reload (init handles the initial apply). The settings UI uses the
  /// individual `set*` methods below for live changes instead.
  void applyStartupSettings(AppSettings s) {
    _snapThreshold = s.snapDistance;
    scaleSnapping = s.scaleSnapping;
    autoRevertOnApply = s.autoRevertOnApply;
    liveApply = s.liveApply;
    autoReapplyOnDrift = s.autoReapplyOnDrift;
    safetyNet.window = Duration(seconds: s.safetyNetSeconds);
    _revertScheduler.defaultDelay =
        Duration(seconds: s.customModeRevertSeconds);
    identifyBannerDuration = Duration(seconds: s.identifyBannerSeconds);
    config.maxBackups = s.maxBackups;
    _mirrorScaling = s.mirrorScaling.arg;
    _workspaceDistribution = s.workspaceManagement.distribution;
    mirrorRunner.scaling = _mirrorScaling;
    config.writeOptions = _effectiveWriteOptions();
  }

  void setSnapDistance(double v) {
    _snapThreshold = v;
    notifyListeners();
  }

  void setScaleSnapping(bool v) {
    scaleSnapping = v;
    notifyListeners();
  }

  /// Toggle live apply at runtime. Switching ON immediately pushes the
  /// current (possibly staged) layout to the compositor so the screen and
  /// the GUI agree; switching OFF just starts staging future edits.
  Future<void> setLiveApply(bool v) async {
    if (liveApply == v) return;
    liveApply = v;
    if (v) {
      _hasUnappliedEdits = false;
      await reloadAndApply();
    }
    notifyListeners();
  }

  void setSafetyNetSeconds(int seconds) {
    safetyNet.window = Duration(seconds: seconds);
  }

  /// True while at least one safety-net revert has failed and the user is
  /// still sitting in the state it was supposed to undo.
  bool get hasFailedSafetyNetRevert => safetyNet.hasFailedRevert;

  /// Re-runs every safety-net revert that previously threw. Returns an
  /// error result naming what is still broken, so a failed retry cannot be
  /// mistaken for a successful one.
  Future<OpResult> retrySafetyNetReverts() async {
    if (!safetyNet.hasFailedRevert) {
      return const OpResult.ok('Nothing to undo.');
    }
    final stillFailing = await safetyNet.retryFailedReverts();
    notifyListeners();
    if (stillFailing.isEmpty) {
      return const OpResult.ok('Put your display back.');
    }
    return OpResult.err(
        'Could not undo: ${stillFailing.join(', ')}. Try re-applying the '
        'profile, or run `kanshictl reload`.');
  }

  void setCustomModeRevertSeconds(int seconds) {
    _revertScheduler.defaultDelay = Duration(seconds: seconds);
  }

  void setIdentifyBannerSeconds(int seconds) {
    identifyBannerDuration = Duration(seconds: seconds);
  }

  void setMaxBackups(int count) {
    config.maxBackups = count;
  }

  /// Change the wl-mirror scaling mode at runtime. Updates both the live
  /// MirrorRunner and the boot-fallback exec line in the kanshi config,
  /// then reloads and restarts the running mirrors so the new mode takes
  /// effect immediately.
  Future<void> setMirrorScaling(String scaling) async {
    if (_mirrorScaling == scaling) return;
    _mirrorScaling = scaling;
    mirrorRunner.scaling = scaling;
    config.writeOptions = _effectiveWriteOptions();
    await _flushSaveAndReload();
    // Restart live mirrors so they pick up the new --scaling: stop all and
    // let reconcile respawn them with the updated runner setting.
    await mirrorRunner.stopAll();
    await _reconcileMirrors();
    notifyListeners();
  }

  // ── Workspace management opt-in ────────────────────────────────────────

  /// Change the workspace-management mode at runtime (settings toggle /
  /// first-run wizard opt-in). Recomputes the effective write options,
  /// rewrites the kanshi config (adding or dropping the `exec swaymsg "…"`
  /// line) and reloads kanshi. When turning management ON, force-applies the
  /// distribution chain so the change lands immediately rather than only on
  /// the next profile activation.
  ///
  /// Turning it OFF removes the exec line and stops re-applying, but does
  /// NOT move workspaces back — there is no pre-management snapshot to
  /// restore to, so the current placement simply stays put until the user
  /// rearranges it themselves. No-op on backends that don't support it.
  Future<void> setWorkspaceDistribution(WorkspaceDistribution? dist) async {
    if (_workspaceDistribution == dist) return;
    _workspaceDistribution = dist;
    config.writeOptions = _effectiveWriteOptions();
    await _flushSaveAndReload();
    if (dist != null && supportsWorkspaceManagement) {
      await _verifyAndFixWorkspacePlacement(force: true);
    }
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
        // Capture the OWNING profile by name, not the list, and not the
        // active index: both go stale during a 15-second countdown.
        final ownerProfile = _profiles[_activeProfileIndex!].name;
        await safetyNet.guard(
          key: 'toggle:$target',
          label: 'Disabled $target',
          doIt: () async {},
          revert: () async {
            final r1 = await monitors.enable(target);
            if (r1.exitCode != 0) {
              throw StateError('could not re-enable $target: ${r1.stderr}');
            }
            final restored = _updateMonitorIn(
                ownerProfile, id, (m) => m.copyWith(enabled: true));
            if (!restored) {
              throw StateError(
                  'turned $target back on, but the profile "$ownerProfile" '
                  'no longer holds it — the saved layout still says disabled');
            }
            final tile = _monitorIn(ownerProfile, id);
            if (tile != null) {
              final r2 = await monitors.apply(tile.copyWith(id: target));
              if (r2.exitCode != 0) {
                throw StateError(
                    'turned $target back on but could not restore its '
                    'layout: ${r2.stderr}');
              }
            }
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
    // Staged mode: hold the change in memory (+ config) until Apply.
    if (!liveApply) return const OpResult.ok();
    if (!target.enabled) return const OpResult.ok();
    try {
      final resolved = _resolveOutputName(target.id);
      final r = await monitors.apply(target.copyWith(id: resolved));
      if (r.exitCode != 0) {
        return OpResult.err('Live apply failed: ${r.stderr}');
      }
      _scheduleLiveApplyRefresh();
      return const OpResult.ok();
    } catch (e) {
      return OpResult.err('Live apply error: $e');
    }
  }

  /// Schedules a `refreshConnectedMonitors()` shortly after a live-apply so
  /// the cached `_currentMonitors` — and the drift banner that depends on
  /// it — track Sway's actual post-apply state. Without this, an apply
  /// that succeeds but gets auto-arranged by the compositor leaves a stale
  /// snapshot in memory and the drift banner never surfaces.
  void _scheduleLiveApplyRefresh() {
    _liveApplyRefreshTimer?.cancel();
    _liveApplyRefreshTimer = Timer(postLiveApplyDelay, () {
      if (_isDisposed) return;
      // Best-effort; refreshConnectedMonitors swallows its own errors.
      // ignore: discarded_futures
      refreshConnectedMonitors();
    });
  }

  /// True if the active profile would have zero enabled outputs after
  /// disabling the monitor at [idx].
  /// True when disabling the output at [idx] would leave the user with no
  /// screen they can actually see.
  ///
  /// This used to count every *enabled* monitor in the profile, including
  /// ones that are not plugged in. A three-output "Home Office" profile used
  /// on the train — where only the laptop panel is live — therefore counted
  /// the two absent externals as "still enabled", let the block pass, and
  /// allowed the one physically present screen to be switched off. The guard
  /// has to reason about what the user can see, so it counts only outputs
  /// that are both enabled and connected.
  bool _wouldLockOutUser(int idx) {
    if (_activeProfileIndex == null) return false;
    final mons = _profiles[_activeProfileIndex!].monitors;
    // Offline editor (no live backend, nothing enumerated): there is no
    // screen to lock the user out of, and connectivity is unknowable. Fall
    // back to the profile-only count so editing a profile for hardware that
    // is not present still behaves.
    final liveKnown = _currentMonitors.isNotEmpty;
    var visibleLeft = 0;
    for (var i = 0; i < mons.length; i++) {
      if (i == idx) continue;
      if (!mons[i].enabled) continue;
      if (liveKnown && !monitorIsConnected(mons[i])) continue;
      visibleLeft++;
    }
    return visibleLeft == 0;
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
      // The profile this mode belongs to, captured now. Resolving against
      // `_activeProfileIndex` when the timer fires would restore the old
      // mode into whatever profile the user had switched to by then.
      final ownerProfile = _profiles[_activeProfileIndex!].name;
      await safetyNet.guard(
        key: 'mode:$target',
        label: 'Mode change on $target',
        doIt: () async {},
        revert: () async {
          // Restore the prior mode at the compositor and in the profile.
          final r = await monitors.setMode(target, priorMode);
          if (r.exitCode != 0) {
            throw StateError(
                'could not put $target back to its previous mode: ${r.stderr}');
          }
          final restored =
              _updateMonitorIn(ownerProfile, priorTile.id, (_) => priorTile);
          if (!restored) {
            throw StateError(
                'restored the mode on $target, but the profile '
                '"$ownerProfile" no longer holds it — the saved layout still '
                'has the new mode');
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

  /// Per-output positional differences (in logical sway-coord pixels) between
  /// the active profile and the applied layout, as of the last hotplug.
  /// Owned by [DriftMonitor]; see there for why it is cached rather than
  /// computed on read.
  List<String> get layoutDriftIssues => _drift.issues;

  void _recomputeDriftIssues() => _drift.recompute(
        isLive: monitors.isLive,
        activeProfile: activeProfile,
        liveOutputs: _currentMonitors,
      );

  /// True when the drift banner should currently be visible: there's an
  /// actual drift AND the user has not already dismissed it for this
  /// hotplug cycle. Cleared on the next hotplug so a new drift surfaces.
  bool get hasLayoutDrift => _drift.shouldSurface;

  /// Hides the drift banner for the current hotplug cycle without applying
  /// any change. The next hotplug event clears the dismissal so a new drift
  /// surfaces again.
  void dismissDriftBanner() {
    if (!_drift.shouldSurface) return;
    _drift.dismiss();
    notifyListeners();
  }

  /// Asks kanshi-daemon to reload its config and re-apply the matched
  /// profile. This is the canonical fix when a hotplug ended up with stale
  /// output positions — equivalent to running `kanshictl reload` by hand.
  /// Refreshes the live output cache so the drift banner immediately
  /// reflects the result.
  Future<OpResult> reapplyActiveProfile() async {
    if (!monitors.isLive) {
      return const OpResult.err(
          'Re-apply only available with a live compositor.');
    }
    // Go through the backend's reload chain (kanshictl → systemd user unit →
    // pkill + setsid restart) instead of shelling out to a bare
    // `kanshictl reload`. On a machine where kanshi is started straight from
    // the sway config — `exec_always … /usr/bin/kanshi -c …`, which is the
    // documented way to run it — there is no kanshictl socket to talk to and
    // the bare call simply fails, so the one-click "put my layout back"
    // button did nothing at all. Verified non-functional on the maintainer's
    // own machine.
    try {
      final r = await monitors.restartCompositorProfileApply();
      if (r.exitCode != 0) {
        final err = r.stderr.toString().trim();
        return OpResult.err(
            'Could not ask kanshi to re-apply${err.isEmpty ? '' : ': $err'}.');
      }
    } catch (e) {
      return OpResult.err('Could not ask kanshi to re-apply: $e');
    }
    await refreshConnectedMonitors();
    _drift.resetDismissal();
    notifyListeners();
    return const OpResult.ok('Layout re-applied.');
  }

  /// Settings toggle: enable/disable automatic `kanshictl reload` when a
  /// hotplug leaves the live layout drifted away from the active profile.
  void setAutoReapplyOnDrift(bool v) {
    if (autoReapplyOnDrift == v) return;
    autoReapplyOnDrift = v;
    notifyListeners();
  }

  /// Debounced auto-reapply: wait ~1.5s after a hotplug for kanshi-daemon
  /// to settle, then fire `kanshictl reload` if drift persists. Bails out
  /// silently if the user dismissed the banner or drift resolved itself.
  void _scheduleDriftAutoReapply() {
    _driftAutoReapplyTimer?.cancel();
    if (!autoReapplyOnDrift) return;
    if (!monitors.isLive) return;
    _driftAutoReapplyTimer = Timer(
      const Duration(milliseconds: 1500),
      () async {
        if (_isDisposed) return;
        if (!autoReapplyOnDrift) return;
        if (layoutDriftIssues.isEmpty) return;
        final r = await reapplyActiveProfile();
        debugPrint('drift auto-reapply: ${r.message ?? "ok"}');
      },
    );
  }

  /// Human-readable problems with the active profile that would make for a
  /// bad apply: no enabled output, or outputs that overlap. Used as a
  /// pre-apply dry-run and surfacable in the UI.
  List<String> validateActiveLayout() {
    final issues = <String>[];
    final idx = _activeProfileIndex;
    if (idx == null) return issues;
    final mons = _profiles[idx].monitors;
    if (mons.where((m) => m.enabled).isEmpty) {
      issues.add('No output is enabled.');
    }
    for (final (a, b) in LayoutMath.findOverlaps(mons)) {
      issues.add('$a and $b overlap.');
    }
    return issues;
  }

  /// If the active profile's outputs overlap, repack them in memory so the
  /// GUI and the about-to-be-written config agree (the writer also guards
  /// this, but fixing the model keeps the canvas truthful). Returns true if
  /// it changed anything.
  bool _resolveActiveOverlapsIfAny() {
    final idx = _activeProfileIndex;
    if (idx == null) return false;
    final mons = _profiles[idx].monitors;
    if (!LayoutMath.hasAnyOverlap(mons)) return false;
    _profiles[idx] = Profile(
      name: _profiles[idx].name,
      monitors: LayoutMath.resolveOverlaps(mons),
    );
    notifyListeners();
    return true;
  }

  Future<OpResult> reloadAndApply() async {
    // Lockout guard: never apply a layout that would leave the user with no
    // visible output. The "last enabled output" rule already protects the
    // toggle path; this catches a profile that arrived disabled-only via
    // load / preset / undo.
    final issues = validateActiveLayout();
    final lockout = issues.firstWhere(
      (i) => i.contains('No output'),
      orElse: () => '',
    );
    if (lockout.isNotEmpty) {
      return OpResult.err('Refusing to apply: $lockout');
    }
    try {
      // Dry-run / auto-fix: never apply an overlapping layout.
      final autoArranged = _resolveActiveOverlapsIfAny();
      // Snapshot the *currently-applied* config (what's on disk right now)
      // BEFORE we overwrite it — that is the last layout the user could see.
      // The auto-revert must restore THAT, not the just-edited (possibly
      // unviewable) one. Null means there was no prior config (fresh
      // install): reverting then means removing what we wrote.
      String? prevRaw;
      try {
        prevRaw = await File(config.configPath).readAsString();
      } catch (_) {
        prevRaw = null;
      }

      await config.saveProfiles(_profiles);
      final r = await monitors.restartCompositorProfileApply();
      if (r.exitCode != 0) {
        return OpResult.err('kanshi restart failed: ${r.stderr}');
      }
      await refreshConnectedMonitors();
      await _loadConfig();
      _hasUnappliedEdits = false;

      // Arm the auto-revert safety net (opt-in, live backends only). If the
      // user can't see the new layout to click "Keep", the window elapses
      // and we restore the previously-applied config automatically. Off by
      // default — routine applies shouldn't pop a countdown.
      if (monitors.isLive && autoRevertOnApply) {
        await safetyNet.guard<void>(
          key: 'layout-apply',
          label: 'Display layout',
          doIt: () async {},
          revert: () async {
            try {
              final f = File(config.configPath);
              if (prevRaw != null) {
                await f.writeAsString(prevRaw);
              } else if (await f.exists()) {
                await f.delete();
              }
              await monitors.restartCompositorProfileApply();
              await _loadConfig();
              await refreshConnectedMonitors();
            } catch (e) {
              debugPrint('layout auto-revert failed: $e');
            }
            notifyListeners();
          },
        );
      }
      if (autoArranged) {
        return const OpResult.ok('Overlapping layout was auto-arranged and applied.');
      }
      return OpResult.ok(monitors.isLive && autoRevertOnApply
          ? 'Applied. Reverting automatically unless you keep it.'
          : 'Applied.');
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
      // Adopt the restored file. Previously this called reloadAndApply(),
      // whose first act is `config.saveProfiles(_profiles)` — so the restored
      // backup was immediately overwritten by the in-memory profiles the user
      // was trying to get away from, and "Restore backup" restored nothing.
      config.invalidateInspectionCache();
      await _loadConfig();
      await refreshConnectedMonitors();
      await _saves.inspect();
      await ensureCurrentSetupMatches(persist: false);
      // Ask kanshi to apply the file we just put back, without rendering
      // anything over it.
      final r = await monitors.restartCompositorProfileApply();
      if (r.exitCode != 0) {
        final err = r.stderr.toString().trim();
        return OpResult.err(
            'Backup restored, but kanshi could not apply it'
            '${err.isEmpty ? '' : ': $err'}.');
      }
      await refreshConnectedMonitors();
      notifyListeners();
      return const OpResult.ok('Backup restored.');
    } catch (e) {
      return OpResult.err('Backup restore failed: $e');
    }
  }

  // ── Helpers exposed for UI ─────────────────────────────────────────────
  MonitorMode? currentModeForOutput(String id) =>
      _currentModeForOutput(_resolveOutputName(id));

  bool monitorIsConnected(MonitorTileData m) =>
      _currentMonitors.any((c) => _matchesOutput(c.id, m.id));

  /// The monitor [outputId] inside the profile named [profileName], looked up
  /// at call time, or null if either is gone.
  MonitorTileData? _monitorIn(String profileName, String outputId) {
    final pIdx = _profiles.indexWhere((p) => p.name == profileName);
    if (pIdx == -1) return null;
    final i =
        _profiles[pIdx].monitors.indexWhere((m) => m.id == outputId);
    return i == -1 ? null : _profiles[pIdx].monitors[i];
  }

  /// Applies [update] to [outputId] inside the profile named [profileName],
  /// re-resolving both at call time. Returns false when either is gone.
  ///
  /// Deferred work — safety-net reverts above all — must never capture a
  /// `List<MonitorTileData>` and write into it after an await. Nearly every
  /// mutation (scaleMonitor, snapAndCommit, the presets, setMirror, …)
  /// replaces the whole [Profile] object, so a captured list becomes an
  /// orphan: the revert wrote into it, nothing read it, and the compositor
  /// and the saved config disagreed from then on. Nor may deferred work
  /// simply use whatever profile happens to be active when the timer fires —
  /// the user may have switched in the meantime, and the change would land
  /// in a profile it was never part of.
  bool _updateMonitorIn(
    String profileName,
    String outputId,
    MonitorTileData Function(MonitorTileData) update,
  ) {
    final pIdx = _profiles.indexWhere((p) => p.name == profileName);
    if (pIdx == -1) return false;
    final mons = _profiles[pIdx].monitors;
    final i = mons.indexWhere((m) => m.id == outputId);
    if (i == -1) return false;
    mons[i] = update(mons[i]);
    _scheduleSave();
    notifyListeners();
    return true;
  }

  // ── Internals ──────────────────────────────────────────────────────────
  void _scheduleSave() {
    // Any scheduled save means the layout was edited; it isn't reflected in
    // the compositor until the next explicit Apply.
    _hasUnappliedEdits = true;
    _saves.schedule(_profiles);
  }

  // Thin aliases onto the domain module. Kept so the ~40 existing call sites
  // read the same as before while the logic itself lives somewhere testable.
  String _normalizeOutputId(String value) => OutputMatcher.normalize(value);

  bool _matchesOutput(String a, String b) => OutputMatcher.same(a, b);

  String _resolveOutputName(String idOrManufacturer) =>
      OutputMatcher.resolveConnector(idOrManufacturer, _currentMonitors);

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

