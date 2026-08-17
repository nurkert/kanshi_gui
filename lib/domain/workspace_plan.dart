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

}

/// What the helper should do about one sway IPC event.
enum SwayEventAction {
  /// Nothing. The default, and the right answer for every workspace event.
  none,

  /// Work the placement out again from scratch: the screens changed, or sway
  /// threw its workspace configs away.
  replan,
}

/// A decision about one event.
class SwayEventVerdict {
  final SwayEventAction action;

  const SwayEventVerdict(this.action);

  static const none = SwayEventVerdict(SwayEventAction.none);
}

/// Reads one line of `swaymsg -t subscribe -m` and decides.
///
/// Deliberately narrow, and narrower than it was.
///
/// It used to act on a workspace being *born*, moving it if sway had put it
/// somewhere else. That fed itself: relocating a workspace means focusing it,
/// focusing it away again leaves it empty, sway garbage-collects an empty
/// workspace, and the next command recreates it — 975 workspace events in
/// three seconds on a real desk, a third of a core burnt, focus yanked between
/// screens faster than a cursor could be moved, and windows appearing to
/// vanish as their workspace was destroyed and remade underneath them.
///
/// The lesson is not "add a guard". It is that a helper must not issue
/// commands in response to events its own commands produce, and the only way
/// to be sure of that is to not react to that class of event at all. What
/// remains cannot loop: the screens changing, and sway throwing its workspace
/// configs away, are things only the outside world does.
///
/// Nothing is lost by it either. Placing a workspace as it is born was a
/// workaround for `workspace N output X` bindings that never reached sway —
/// which is the bug 2.1.1 actually fixed. sway does this itself now.
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
  // Narrow, and deliberately so: the two shapes sway actually sends, rather
  // than "anything without a `current`". A malformed or future event should
  // mean "do nothing", not "go and rearrange the desk".
  if (change == 'reload') {
    return const SwayEventVerdict(SwayEventAction.replan);
  }
  if (change == 'unspecified' && !event.containsKey('current')) {
    return const SwayEventVerdict(SwayEventAction.replan);
  }

  // Everything else is a workspace event: something opened, closed, was
  // focused or was moved. All of it is either the user's doing or our own,
  // and neither is ours to answer.
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
    // Compared through the same reduction the writer applies on the way out.
    // `~/.current_kanshi_profile` is written by a shell `echo`, and a name a
    // shell cannot be trusted with is written in its printable form — so a
    // literal comparison silently never matched for any setup named with an
    // apostrophe or a bracket, and the tie-break quietly did nothing.
    final wanted = shellSafeText(preferProfileName);
    for (final p in candidates) {
      if (shellSafeText(p.name) == wanted) return p;
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
