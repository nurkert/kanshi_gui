// Pure Dart. No Flutter, no dart:io — the helper daemon is a separate binary
// with no Flutter engine behind it, and this is the part it shares with the
// app. Keeping it pure is what stops the two from drifting into two different
// answers to "where does workspace 9 go".

import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/domain/output_matcher.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// Where every numeric workspace belongs, for the screens that are plugged in
/// right now, expressed in the connector names sway currently uses.
class WorkspacePlan {
  /// The remembered setup the live screens were recognised as.
  final Profile profile;

  /// Workspace number → live connector, for every workspace in range.
  final Map<int, String> map;

  /// How each of those connectors should be addressed in a sway command.
  final Map<String, OutputCriteria> criteria;

  const WorkspacePlan({
    required this.profile,
    required this.map,
    required this.criteria,
  });

  /// Declarations plus the focus-and-move pass: relocates workspaces that
  /// already exist. Visible, so it is for moments where something changed.
  String? get chain => buildWorkspaceChain(map, criteria: criteria);

  /// The `workspace N output X` half alone. Invisible, and the half that
  /// decides where a workspace that does not exist yet will be born.
  String? get declarations =>
      buildWorkspaceDeclarations(map, criteria: criteria);

  /// The command that puts one workspace where it belongs, or null if this
  /// plan has no opinion about that workspace.
  ///
  /// Moving a workspace in sway means focusing it first — there is no way to
  /// relocate one you are not on. That is invisible when the workspace was
  /// just created (it already has focus), and rude when it was not: a user
  /// who pressed `$mod+8` and then immediately `$mod+1` would be yanked back
  /// to 8 by a command that arrived a few milliseconds late. Pass
  /// [returnFocusTo] with wherever the user actually is and the chain hands
  /// focus back in the same atomic command.
  String? moveOne(int workspace, {int? returnFocusTo}) {
    final target = map[workspace];
    if (target == null) return null;
    final c = criteria[target] ?? OutputCriteria.connector(target);
    // Same gate as the full chain: a target that cannot be safely quoted
    // means no command at all. See [buildWorkspaceDeclarations].
    if (!c.isShellSafe) return null;
    final move = 'workspace number $workspace; '
        'move workspace to output ${c.swayExecForm}';
    if (returnFocusTo == null || returnFocusTo == workspace) return move;
    return '$move; workspace number $returnFocusTo';
  }
}

/// What the helper should do about one sway IPC event.
enum SwayEventAction {
  /// Nothing. The default, and the right answer for most events.
  none,

  /// Work the placement out again from scratch: the screens changed, or sway
  /// threw its workspace configs away.
  replan,

  /// A workspace was just created. Put it where it belongs, if it is not
  /// already there.
  placeOne,
}

/// A decision about one event, and what it is about.
class SwayEventVerdict {
  final SwayEventAction action;

  /// The workspace number, for [SwayEventAction.placeOne].
  final int? workspace;

  /// The screen sway put it on.
  final String? on;

  const SwayEventVerdict(this.action, {this.workspace, this.on});

  static const none = SwayEventVerdict(SwayEventAction.none);
}

/// Reads one line of `swaymsg -t subscribe -m` and decides.
///
/// Deliberately narrow. In particular a `move` is NOT acted on: a user who
/// drags a workspace to another screen has said something, and a helper that
/// dragged it back would be unusable. Only a workspace being *born* — the one
/// moment no config file can reach, because sway has already chosen an output
/// by the time anything else could look — and the events that mean the plan
/// itself is stale.
SwayEventVerdict classifySwayEvent(Map<String, dynamic> event) {
  final change = event['change']?.toString();

  // An output event carries NOTHING but a change, and the change is always
  // the string "unspecified":
  //
  //     { "change": "unspecified" }
  //
  // This looked for an `output` key, reasoning that an event about outputs
  // would name one. It does not, and sway has never sent one — so the branch
  // never ran and the daemon never replanned on a hotplug. Docking did
  // nothing at all; the placement it had computed at session start simply
  // stayed. Captured from a live sway rather than assumed a second time.
  //
  // `current` is what a workspace event carries, so its absence is the
  // discriminator. That also catches the workspace `reload` event, which has
  // no `current` either — and wants the same answer: `swaymsg reload` throws
  // away every workspace config sway holds, which is exactly why it is the
  // documented way out of a workspace stuck on the wrong screen. It throws
  // away ours too, so put them back.
  if (!event.containsKey('current') || change == 'reload') {
    return const SwayEventVerdict(SwayEventAction.replan);
  }

  if (change == 'init') {
    final current = event['current'];
    if (current is! Map) return SwayEventVerdict.none;
    final num = current['num'];
    if (num is! int || num < 1) return SwayEventVerdict.none;
    return SwayEventVerdict(
      SwayEventAction.placeOne,
      workspace: num,
      on: current['output']?.toString(),
    );
  }

  return SwayEventVerdict.none;
}

/// Whether [profile] describes exactly the screens in [live].
///
/// The same question kanshi asks before activating a profile, and it has to
/// be the same answer: correspondence in both directions. A profile that
/// merely happens to name one of the connected screens is not this desk, and
/// acting on it would pin workspaces to a monitor arrangement the user is not
/// sitting at.
bool profileMatchesLive(Profile profile, List<MonitorTileData> live) {
  final entries = profile.monitors;
  if (entries.isEmpty || entries.length != live.length) return false;
  return OutputMatcher.pair(entries, live).length == entries.length;
}

/// Picks the setup the live screens are, preferring [preferProfileName] when
/// it is among the candidates.
///
/// The preference is how the daemon uses `~/.current_kanshi_profile`: kanshi
/// writes the name of the profile it just activated, which disambiguates two
/// remembered setups that describe the same hardware in different positions.
/// It is only ever a tiebreak — the file survives reboots and describes
/// yesterday's desk until kanshi gets round to rewriting it, so a name that
/// does not match what is plugged in now is ignored rather than trusted.
Profile? matchProfile(
  List<Profile> profiles,
  List<MonitorTileData> live, {
  String? preferProfileName,
}) {
  final candidates = [
    for (final p in profiles)
      if (profileMatchesLive(p, live)) p,
  ];
  if (candidates.isEmpty) return null;
  if (preferProfileName != null) {
    for (final p in candidates) {
      if (p.name == preferProfileName) return p;
    }
  }
  return candidates.first;
}

/// Works out where the numbers go, for the screens that are actually there.
///
/// Returns null when there is nothing to say: no setup recognised, none of
/// its screens connected, or the caller passed a distribution of null because
/// the user has the feature switched off. A null plan means *do nothing* —
/// never "fall back to something reasonable". Half a plan applied to a desk
/// the app does not recognise is how workspaces end up pinned to a monitor
/// that is not there.
WorkspacePlan? planWorkspaces({
  required List<Profile> profiles,
  required List<MonitorTileData> live,
  required WorkspaceDistribution? distribution,
  bool followProfileMap = false,
  String? preferProfileName,
  int maxWorkspaces = 9,
}) {
  if (distribution == null) return null;
  if (live.isEmpty) return null;
  final profile =
      matchProfile(profiles, live, preferProfileName: preferProfileName);
  if (profile == null) return null;

  // The same predicate the writer uses when it renders the exec chain: a
  // mirror destination shows another screen's picture and must not be given
  // workspaces of its own.
  final connected = {for (final m in live) m.id};
  final resolved = <MonitorTileData>[];
  for (final m in profile.monitors) {
    if (!m.enabled || m.mirrorOf != null) continue;
    final connector = OutputMatcher.resolveConnector(m.id, live);
    if (!connected.contains(connector)) continue;
    resolved.add(m.copyWith(id: connector));
  }
  if (resolved.isEmpty) return null;

  final ranked = resolveWorkspaceRanks(resolved);
  if (ranked.isEmpty) return null;

  // Restated in live connector names, because the setup may address its
  // screens by EDID descriptor while `ranked` is keyed by the port sway is
  // using this boot. An entry that cannot be restated onto a connected screen
  // is dropped by [resolveWorkspaceMap] and the rule answers for it instead.
  final learned = !followProfileMap || profile.workspaceMap == null
      ? null
      : {
          for (final e in profile.workspaceMap!.entries)
            e.key: OutputMatcher.resolveConnector(e.value, live),
        };

  final descriptors = {
    for (final m in live)
      if (m.edidDescriptor.isNotEmpty) m.id: m.edidDescriptor,
  };
  return WorkspacePlan(
    profile: profile,
    map: resolveWorkspaceMap(
      ranked,
      maxWorkspaces: maxWorkspaces,
      distribution: distribution,
      learned: learned,
    ),
    // Descriptors as sway reports them, not as the config remembers them: the
    // daemon is talking to sway, and a stale descriptor is one sway silently
    // fails to resolve. Two panels of the same model share one, and
    // [chooseExecCriteria] drops that pair back to connector names.
    //
    // The exec chooser, not the config one, even though nothing here goes
    // through a shell. It costs nothing — a connector is a perfectly good
    // address over IPC — and it buys the guarantee that the app, the helper
    // and the config file name each screen the same way. Three components
    // that disagree about which screen `workspace 9` means is a bug nobody
    // would find twice.
    criteria: chooseExecCriteria(
      resolved.map((m) => m.id),
      (connector) => descriptors[connector],
    ),
  );
}
