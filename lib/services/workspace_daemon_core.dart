// Pure Dart. No Flutter, no dart:io — the helper is a separate binary and
// this is the part of it that decides things.

import 'dart:async';

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
      log('no remembered setup matches these screens');
      return;
    }

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
        // on workspace 1.
        ? buildWorkspaceChain(plan.map,
            criteria: plan.criteria,
            returnFocusTo: await sway.focusedWorkspace())
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
