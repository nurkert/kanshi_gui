// Pure Dart. No Flutter, no dart:io — the helper is a separate binary and
// this is the part of it that decides things.

import 'dart:async';

import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/domain/workspace_plan.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';

/// Everything the helper needs from the compositor, small enough to fake.
///
/// This interface exists because of an incident. The helper reacted to a
/// workspace being created by relocating it; relocating means focusing;
/// focusing away empties the previous one; sway collects an empty workspace;
/// the next command recreates it. 975 workspace events in three seconds on a
/// real desk, a third of a core, and a desktop nobody could use.
///
/// Seven hundred tests did not catch it, and could not have: every one of them
/// asserted on the strings the code produced, and this bug lives in what the
/// compositor does with them afterwards. So the deciding half moved behind
/// this interface, and the tests drive it with a sway that answers commands
/// with the events real sway would answer them with. See
/// test/fakes/fake_sway.dart.
abstract class SwayConnection {
  /// The subscribed event stream, already decoded.
  Stream<Map<String, dynamic>> events();

  /// `swaymsg -t get_outputs`, reduced to identity — geometry comes from the
  /// remembered setup, not from the live state.
  Future<List<MonitorTileData>> outputs();

  /// `swaymsg -t get_workspaces`, as workspace number → output name.
  Future<Map<int, String>> workspaceOutputs();

  /// The numeric workspace the user is looking at, or null when it has none.
  Future<int?> focusedWorkspace();

  /// Sends one command. Returns false when it could not be delivered.
  Future<bool> run(String command);
}

/// The two files the helper reads, and the marker kanshi leaves behind.
abstract class DaemonEnvironment {
  Future<AppSettings> settings();
  Future<List<Profile>> profiles();

  /// `~/.current_kanshi_profile`, or null. A tie-break, never an instruction.
  Future<String?> markedProfile();
}

/// Why an apply was asked for. Only one of these may move a workspace that is
/// already open.
enum ApplyReason {
  /// The service just attached to a sway session.
  startup,

  /// A screen appeared or disappeared, or sway threw its workspace configs
  /// away. The one moment a flicker is expected anyway.
  outputsChanged,

  /// The app changed its mind — a pattern, a dragged number, a rewritten
  /// config. Says where things belong from now on; never moves what is open.
  configChanged,
}

/// The helper's decisions, with the compositor and the filesystem held at
/// arm's length.
class WorkspaceDaemonCore {
  final SwayConnection sway;
  final DaemonEnvironment env;
  final void Function(String message) log;

  /// Set for `--dry-run`: everything is worked out, nothing is sent.
  final bool dryRun;

  /// Taken around the send so the app and the helper cannot walk the
  /// workspaces at the same time. Injectable so tests need no filesystem.
  final Future<bool> Function(Future<void> Function())? withApplyLock;

  WorkspaceDaemonCore({
    required this.sway,
    required this.env,
    this.log = _ignore,
    this.dryRun = false,
    this.withApplyLock,
  });

  static void _ignore(String _) {}

  /// Commands actually sent, in order. The loop test counts these.
  final List<String> sent = [];

  /// When each recent apply happened, for [_runaway].
  final List<DateTime> _applies = [];

  /// How many applies in a minute is too many. Docking produces one, a reload
  /// one, a settings change one — a dozen is far above any real desk.
  static const int applyCeiling = 12;

  /// How long before the same workspace may be corrected again.
  ///
  /// A correction that works needs no repeat: the workspace is on its screen
  /// and the next switch to it agrees. A correction that does NOT work — a
  /// target sway cannot resolve, a screen that went away between the plan and
  /// the command — would otherwise fire on every single workspace switch for
  /// the rest of the session.
  static const Duration correctionCooldown = Duration(seconds: 10);

  /// Ceiling for corrections, counted separately from applies: switching
  /// briskly through nine workspaces in a session with stale bindings is
  /// legitimate and would otherwise trip the apply ceiling and leave the desk
  /// half repaired.
  static const int correctionCeiling = 20;

  /// The placement the last [apply] worked out. Held so a correction costs a
  /// map lookup rather than reading two files and asking sway what it has.
  WorkspacePlan? _plan;

  /// Visible for tests: what the helper currently believes.
  WorkspacePlan? get plan => _plan;

  final Map<int, DateTime> _correctedAt = {};
  final List<DateTime> _corrections = [];

  /// The workspace of the most recent focus event, recorded the moment the
  /// event arrives rather than when the correction reaches the front of the
  /// queue.
  ///
  /// A repair chain focuses all nine workspaces on its way through, so nine
  /// focus events land while the chain is still running and every one of them
  /// describes a workspace that the chain is about to move. Acting on them
  /// would mean nine pointless commands after every dock. Only the last focus
  /// still describes where the user actually is.
  int? _latestFocus;

  /// Called synchronously as the event is read, before anything is queued.
  void noteFocus(int workspace) => _latestFocus = workspace;

  /// Workspaces the user has moved themselves.
  ///
  /// sway has a `move workspace to output` binding of its own, and someone who
  /// presses it has said something more specific than any rule the app holds.
  /// Correcting them back would be a fight they cannot win — the rule answers
  /// again on every visit — so the first time a workspace is moved by someone
  /// other than us, it stops being ours to place for the rest of the session.
  final Set<int> _movedByHand = <int>{};

  /// The workspace this helper is moving right now, so its own `move` event is
  /// not read as the user's.
  int? _movingOurselves;

  /// A screen appeared or disappeared and the placement is being worked out
  /// again. Until it is, the cached plan describes the previous desk — and
  /// correcting against it would drag workspaces back onto the screen they
  /// just came off. Docking settles over seconds, not milliseconds.
  bool _replanning = false;

  /// Called when a replan is scheduled, and again when it has finished.
  // ignore: avoid_positional_boolean_parameters
  void replanPending(bool pending) => _replanning = pending;

  /// One `move` event. Returns true when it was read as the user's own doing.
  ///
  /// Three things emit `move` and only one of them is a decision:
  ///
  ///  * this helper, which knows what it just sent;
  ///  * sway, relocating workspaces onto a screen that just appeared — which
  ///    it does from the bindings, so it happens on every dock. Measured: it
  ///    logged "workspace 3 was moved by hand" while plugging a dock in, and
  ///    would then have stopped placing workspace 3 for the session;
  ///  * the user, on their own keybinding.
  ///
  /// The first is excluded by memory, the second by only counting moves that
  /// land a workspace somewhere the plan does NOT put it. A move onto its own
  /// screen is not an override, it is agreement — which also covers the app's
  /// repair chain, running in another process where no memory would reach.
  bool noteMove(int workspace, String output) {
    if (_movingOurselves == workspace) {
      _movingOurselves = null;
      return false;
    }
    if (_replanning) return false;
    final want = _plan?.map[workspace];
    if (want == null || want == output) return false;
    if (!_movedByHand.add(workspace)) return true;
    log('workspace $workspace was moved by hand; leaving it be from now on');
    return true;
  }

  Future<void> _queue = Future<void>.value();

  /// Runs [action] after everything already queued.
  ///
  /// Both things the helper does end in a command, and both are reached from
  /// handlers that do not wait for each other. Interleaving two command
  /// streams into one compositor produces a state neither of them asked for —
  /// and the "does the live layout disagree" question, asked halfway through
  /// someone else's moves, gets an answer that was never true.
  Future<void> serialised(Future<void> Function() action) {
    final next = _queue.then((_) async {
      try {
        await action();
      } catch (e) {
        log('step failed: $e');
      }
    });
    _queue = next;
    return next;
  }

  /// Puts one workspace back on its screen, and touches nothing else.
  ///
  /// Called when the user switches to a workspace that is not where the setup
  /// says it lives. That happens for two reasons, and neither is fixable from
  /// the declarations alone: a session that started before this version has
  /// stale `workspace N output X` bindings in it that only a logout clears,
  /// and no single fixed preference list can be right for two nested setups
  /// that disagree — see [workspaceHomes].
  ///
  /// The command is one `move workspace to output`, on the workspace the user
  /// is already looking at, so nothing is taken away from them: they asked for
  /// this workspace, and it arrives on the screen they put it on. See
  /// [classifySwayEvent] for the measurement showing this cannot feed itself.
  Future<void> correct(int workspace, String liveOutput, {DateTime? now}) async {
    final plan = _plan;
    if (plan == null) return;
    if (_replanning) return;
    if (_movedByHand.contains(workspace)) return;
    if (_latestFocus != null && _latestFocus != workspace) return;
    final want = plan.map[workspace];
    if (want == null || want == liveOutput) return;

    final at = now ?? DateTime.now();
    final last = _correctedAt[workspace];
    if (last != null && at.difference(last) < correctionCooldown) return;
    _corrections.removeWhere((t) => at.difference(t) > const Duration(minutes: 1));
    if (_corrections.length >= correctionCeiling) {
      log('too many corrections in a minute — standing down until it settles');
      return;
    }

    // The event said where the workspace was when it was focused. Between
    // then and now the user may have moved on, and `move workspace to output`
    // acts on whatever is focused NOW — so it would drag a workspace nobody
    // asked about. One round trip buys the guarantee that the thing we are
    // about to move is the thing we decided to move.
    final int? focused;
    try {
      focused = await sway.focusedWorkspace();
    } catch (e) {
      log('correction: could not confirm the focused workspace: $e');
      return;
    }
    if (focused != workspace) return;

    _correctedAt[workspace] = at;
    _corrections.add(at);
    final target = plan.criteria[want] ?? OutputCriteria.connector(want);
    final command = 'move workspace to output ${target.swayExecForm}';
    log('workspace $workspace is on $liveOutput, not $want — moving it');
    if (dryRun) {
      log('would send: $command');
      return;
    }
    Future<void> send() async {
      sent.add(command);
      _movingOurselves = workspace;
      await sway.run(command);
    }

    final lock = withApplyLock;
    if (lock == null) {
      await send();
    } else if (!await lock(send)) {
      // A full apply is in flight and is on its way to the same end state.
      // Forget the cooldown so the next switch tries again if it was not.
      _correctedAt.remove(workspace);
      _corrections.remove(at);
      log('another apply is in flight; leaving it to them');
    }
  }

  bool _runaway(DateTime now) {
    _applies.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_applies.length >= applyCeiling) {
      log('too many applies in a minute — standing down until it settles');
      return true;
    }
    _applies.add(now);
    return false;
  }

  /// Decides what one event means. Output changes and sway discarding its
  /// workspace configs are the only things the helper answers; see
  /// [classifySwayEvent] for why that list is so short.
  ApplyReason? reasonFor(Map<String, dynamic> event) =>
      classifySwayEvent(event).action == SwayEventAction.replan
          ? ApplyReason.outputsChanged
          : null;

  /// Works out where the numbers go and tells sway, if there is anything to
  /// tell it.
  Future<void> apply(ApplyReason reason, {DateTime? now}) async {
    if (_runaway(now ?? DateTime.now())) return;

    final settings = await env.settings();
    final mode = settings.workspaceManagement;
    if (!mode.enabled) {
      // Also drops the cached plan: a correction fired against a placement the
      // user has since switched off would be the one thing this service must
      // never do.
      _plan = null;
      log('placement is switched off');
      return;
    }

    final live = await sway.outputs();
    if (live.isEmpty) return;
    final profiles = await env.profiles();
    if (profiles.isEmpty) return;

    final plan = planWorkspaces(
      profiles: profiles,
      live: live,
      distribution: mode.distribution,
      followProfileMap: mode.followsMap,
      preferProfileName: await env.markedProfile(),
    );
    if (plan == null) {
      _plan = null;
      log('no remembered setup matches these screens');
      return;
    }
    if (_plan?.profile.name != plan.profile.name) {
      // A different desk. What someone chose to do with a workspace at the
      // last one says nothing about this one.
      _movedByHand.clear();
    }
    _plan = plan;

    // Which half runs is the difference between invisible and disruptive.
    //
    // Declaring costs nothing and touches nothing that exists. The other half
    // walks the workspaces, focusing each in turn, because that is the only
    // way sway will relocate one — and a background service that does that
    // while someone is working has taken their screen away from them.
    //
    // So it needs BOTH a reason and permission: the live layout has to
    // actually disagree, AND the trigger has to be a screen appearing, which
    // is the one moment a flicker is expected anyway.
    final actual = await sway.workspaceOutputs();
    final disagrees = actual.entries.any((e) {
      final want = plan.map[e.key];
      return want != null && want != e.value;
    });
    final disturb = disagrees && reason == ApplyReason.outputsChanged;

    final command = disturb
        // Handed back to whatever the user was on, instead of dropping them
        // on workspace 1. And carrying `homes`, because the chain's first half
        // IS a declaration: without it this path re-emitted one screen per
        // workspace — the exact shape sway keeps forever and ignores every
        // correction to — from the one code path that runs on every dock.
        ? buildWorkspaceChain(plan.map,
            criteria: plan.criteria,
            returnFocusTo: await sway.focusedWorkspace(),
            homes: plan.homes.isEmpty ? null : plan.homes)
        : plan.declarations;
    if (command == null) return;

    log('${plan.profile.name}: ${disturb ? 'repairing' : 'declaring'} '
        '${plan.map.entries.map((e) => '${e.key}→${e.value}').join(' ')}');
    if (dryRun) {
      log('would send: $command');
      return;
    }
    Future<void> send() async {
      sent.add(command);
      await sway.run(command);
    }

    final lock = withApplyLock;
    if (lock == null) {
      await send();
    } else if (!await lock(send)) {
      // Someone else is mid-apply. They are on their way to the same end
      // state, and two walks interleaved end wherever the last one landed.
      log('another apply is in flight; leaving it to them');
    }
  }
}
