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

  /// Every screen each workspace could be born on, most-preferred first,
  /// across all remembered setups. See [workspaceHomes] for why a binding
  /// must not name only the screen that happens to be plugged in.
  final Map<int, List<OutputCriteria>> homes;

  const WorkspacePlan({
    required this.profile,
    required this.map,
    required this.criteria,
    this.homes = const {},
  });

  /// Declarations plus the focus-and-move pass: relocates workspaces that
  /// already exist. Visible, so it is for moments where something changed.
  String? get chain =>
      buildWorkspaceChain(map, criteria: criteria, homes: _homes);

  /// The `workspace N output X …` half alone. Invisible, and the half that
  /// decides where a workspace that does not exist yet will be born.
  String? get declarations => buildWorkspaceDeclarations(_homes);

  Map<int, List<OutputCriteria>> get _homes =>
      homes.isEmpty ? homesFromMap(map, criteria: criteria) : homes;
}

/// What the helper should do about one sway IPC event.
enum SwayEventAction {
  /// Nothing. The default, and the right answer for every workspace event.
  none,

  /// Work the placement out again from scratch: the screens changed, or sway
  /// threw its workspace configs away.
  replan,

  /// The user just switched to a workspace and it is on the wrong screen.
  /// Move that one workspace, and nothing else.
  correct,

  /// The user moved a workspace to another screen themselves. Not something
  /// to answer — something to remember, and stop answering.
  userMoved,
}

/// A decision about one event.
class SwayEventVerdict {
  final SwayEventAction action;

  /// For [SwayEventAction.correct]: the workspace the user is looking at.
  final int? workspace;

  /// For [SwayEventAction.correct]: the screen it is on right now.
  final String? output;

  const SwayEventVerdict(this.action, {this.workspace, this.output});

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
/// What IS lost by it is one thing, and it is the reason [SwayEventAction.
/// correct] exists below. This paragraph used to end "sway does this itself
/// now", on the theory that once the bindings actually reached sway it would
/// place a new workspace correctly. It does not always: it takes the FIRST
/// binding it was ever given for that workspace, so a session carrying a
/// stale one places it wrongly forever, and no fixed preference list can be
/// right for two nested setups that disagree. Answering a workspace being
/// BORN is still out of the question; answering the one the user just
/// switched to, with one move, is not.
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
  // `current` is what an ordinary workspace event carries, so its absence is
  // the discriminator for an output event.
  //
  // The workspace `reload` event is checked separately and by name, because
  // it DOES carry a `current` key — a null one. Measured against a live sway
  // rather than assumed: `swaymsg reload` emits
  // `{change: reload, current: null, old: null}` and, on top of that, two
  // `{change: unspecified}` output events. An earlier comment here claimed
  // reload had no `current` and that the missing-`current` rule caught it;
  // it does not, and the explicit branch below is what does.
  // Narrow, and deliberately so: the two shapes sway actually sends, rather
  // than "anything without a `current`". A malformed or future event should
  // mean "do nothing", not "go and rearrange the desk".
  if (change == 'reload') {
    return const SwayEventVerdict(SwayEventAction.replan);
  }
  if (change == 'unspecified' && !event.containsKey('current')) {
    return const SwayEventVerdict(SwayEventAction.replan);
  }

  // The one workspace event worth answering, and the narrowest possible
  // answer to it: the user switched to a workspace and it is somewhere the
  // setup does not put it.
  //
  // This is not a walk back to the old design. What burnt a third of a core
  // was reacting to a workspace being BORN by running the whole nine-step
  // focus-and-move chain: relocating means focusing, focusing away leaves the
  // previous one empty, sway collects an empty workspace, and the next
  // command recreates it. Measured on sway 1.12, a single
  // `move workspace to output X` on the already-focused workspace emits
  // `move`, an `empty` for whatever the destination was showing, and an
  // `init` for the workspace sway auto-creates on the screen just vacated —
  // and NOT a `focus`. So the one event class this reacts to is the one class
  // its own command cannot produce, which is what makes it safe rather than
  // merely guarded. The auto-created workspace arrives unfocused and is
  // ignored for the same reason.
  //
  // It earns its place because the declarations cannot be right for every
  // desk at once — see [workspaceHomes] — and because a session that started
  // before this version has stale bindings in it that nothing else can undo
  // short of logging out.
  if (change == 'focus' || change == 'move') {
    final current = event['current'];
    if (current is Map) {
      final num = current['num'];
      final output = current['output'];
      if (num is int && num > 0 && output is String && output.isNotEmpty) {
        return SwayEventVerdict(
            change == 'move'
                ? SwayEventAction.userMoved
                : SwayEventAction.correct,
            workspace: num,
            output: output);
      }
    }
    return SwayEventVerdict.none;
  }

  // Everything else is a workspace event: something opened, closed, was
  // renamed or was moved. All of it is either the user's doing or our own,
  // and neither is ours to answer.
  return SwayEventVerdict.none;
}

/// Every screen each workspace could be born on, most-preferred first,
/// across every remembered setup.
///
/// This exists because a `workspace N output X` binding outlives the desk it
/// was written for. sway appends bindings and never clears them, and it takes
/// the first one that resolves to a connected screen — so the first binding a
/// session sees wins for the rest of that session, and re-declaring is a
/// silent no-op. See [buildWorkspaceConfigExecs] for the measurements, and for
/// why `swaymsg reload` — the one reset sway offers — is not usable.
///
/// The way out is to declare the whole preference list at once and let sway
/// pick the first screen that is actually there. That only works if the list
/// is the same every time: a list that depended on what is plugged in would
/// stack a different order on every dock and put us straight back where we
/// started. So the order here is deliberately blind to the live outputs.
///
/// **Narrowest reach first.** A screen that belongs to many remembered setups
/// goes last; a screen only one setup has goes first.
///
/// That is not a preference, it falls out of how sway reads the list. An entry
/// is only ever reached if everything before it is absent, so a screen that is
/// present at every desk — a laptop panel, typically — makes everything after
/// it dead. First, it answers for every desk; last, it answers only when
/// nothing more specific is there, which is what a fallback is.
///
/// Ordering by setup size instead is the obvious idea, and it gets the common
/// case backwards. Measured on a real config: a three-screen home setup whose
/// leftmost screen is the laptop panel and a three-screen office setup whose
/// leftmost screen is an external monitor are the same size, the tie fell to
/// config order, and `workspace 1` came out as
/// `output 'eDP-1' 'Samsung …HK2XA01318'`. At the office desk the panel is
/// plugged in, so workspace 1 would be born on the laptop instead of on the
/// left screen — this function's own bug, one layer up.
///
/// It is still not right for *every* desk at once, and it cannot be: two
/// setups whose screens are nested and which disagree about one workspace each
/// need to precede the other, and no single list can do both.
///
/// Where exactly it fails, measured rather than argued — an earlier version of
/// this paragraph claimed "the ordinary nested case always comes out right",
/// and that was checked and found false. The residue is:
///
///   * A smaller setup nested inside a larger one **and sharing at least two
///     screens with it** — laptop + monitor inside laptop + monitor + dock
///     screen. Some of the nine come out wrong at one of the two desks, every
///     session: four of nine in the shape the test pins. Which desk carries
///     them is what the tie-break decides, and reversing it moves the same
///     four to the other desk rather than removing any. The larger desk wins
///     here, on the grounds that it is where more screens are in play and
///     where a misplaced number is more visible.
///   * A setup nested inside another sharing exactly ONE screen — the
///     laptop-only fallback inside a docked desk, which is the common shape —
///     comes out right at both. All nine, measured on the config this was
///     found on.
///
/// The residue is what the helper's live correction is for; see
/// [SwayEventAction.correct]. The helper is opt-in, so for someone who has not
/// switched it on, those two numbers stay where sway put them until the app is
/// opened. Say so rather than imply otherwise.
Map<int, List<OutputCriteria>> workspaceHomes({
  required List<Profile> profiles,
  required WorkspaceDistribution? distribution,
  bool followProfileMap = false,
  int maxWorkspaces = 9,
}) {
  if (distribution == null) return const {};

  // How many remembered setups each screen belongs to. Counted over setups
  // rather than over how often a screen is chosen for a workspace: what
  // decides whether an entry can shadow a later one is only whether it is
  // plugged in, which is a property of the desk.
  final reach = <String, int>{};
  for (final profile in profiles) {
    for (final id in {
      for (final m in _placeableScreens(profile)) _screenIdentity(m),
    }) {
      reach[id] = (reach[id] ?? 0) + 1;
    }
  }

  final candidates = <int, List<_WorkspaceHome>>{};
  for (var i = 0; i < profiles.length; i++) {
    final profile = profiles[i];
    final mons = _placeableScreens(profile);
    if (mons.isEmpty) continue;
    final ranked = resolveWorkspaceRanks(mons);
    if (ranked.isEmpty) continue;
    // Addressed by EDID descriptor wherever the setup has ever seen one. A
    // screen that is not plugged in has no connector to name, and the
    // connector a dock hands out is not the one it handed out last week; the
    // descriptor is the only address that survives being absent.
    final criteria = chooseExecCriteria(
      mons.map((m) => m.id),
      (id) {
        final m = mons.firstWhere((e) => e.id == id);
        return m.edidDescriptor.isEmpty ? null : m.edidDescriptor;
      },
    );
    final map = resolveWorkspaceMap(
      ranked,
      maxWorkspaces: maxWorkspaces,
      distribution: distribution,
      // Restated in this setup's own ids first. An observation is recorded
      // against the connector sway reported, while a setup may address the
      // same screen by EDID descriptor — and [resolveWorkspaceMap] drops an
      // overlay entry it cannot recognise, which would quietly discard the
      // nine deliberate choices that mode exists to keep.
      learned: followProfileMap
          ? rekeyWorkspaceMap(profile.workspaceMap, mons)
          : null,
    );
    for (final entry in map.entries) {
      final screen = mons.firstWhere((m) => m.id == entry.value,
          orElse: () => mons.first);
      final identity = _screenIdentity(screen);
      final crit =
          criteria[entry.value] ?? OutputCriteria.connector(entry.value);
      final list = candidates.putIfAbsent(entry.key, () => <_WorkspaceHome>[]);
      // Deduplicated by SPELLING, not by screen. Two setups usually spell a
      // display the same way, and then this collapses them. They differ when
      // one setup holds two displays that share a description and has to fall
      // back to connector names for both — and a connector is a different
      // address at a different dock. Collapsing those onto one screen dropped
      // the spelling that was the only one that resolved at the other desk.
      if (!list.any((h) => h.criteria == crit)) {
        list.add(_WorkspaceHome(identity, crit, i, mons.length));
      }
    }
  }

  return {
    for (final entry in candidates.entries)
      entry.key: (entry.value.toList()
            ..sort((a, b) {
              final byReach =
                  (reach[a.identity] ?? 0).compareTo(reach[b.identity] ?? 0);
              if (byReach != 0) return byReach;
              // Equal reach, and one of them has to be wrong somewhere. The
              // bigger desk wins: more of its screens are plugged in when it
              // is the one you are at, so more of the list below it is live
              // and more of it is shadowed. Config order last, so the answer
              // never depends on which setup you happened to save first.
              final bySize = b.deskSize.compareTo(a.deskSize);
              return bySize != 0 ? bySize : a.order.compareTo(b.order);
            }))
          .map((h) => h.criteria)
          .toList(),
  };
}

/// One candidate screen for one workspace, before the list is ordered.
class _WorkspaceHome {
  /// The screen itself, independent of how a given setup spells it. Only used
  /// for ordering; two spellings of one screen are both kept.
  final String identity;
  final OutputCriteria criteria;

  /// Which setup put it forward, so equal reach breaks deterministically.
  final int order;

  /// How many screens that setup has.
  final int deskSize;

  const _WorkspaceHome(this.identity, this.criteria, this.order, this.deskSize);
}

/// What makes two entries in two different setups the same physical screen.
///
/// The EDID descriptor when there is one — it survives a reboot and a change
/// of port, which is why the app records it at all — and the connector
/// otherwise.
String _screenIdentity(MonitorTileData m) =>
    m.edidDescriptor.isNotEmpty ? m.edidDescriptor : m.id;

/// Restates an observed `workspace → output` map in terms of [mons]' own ids.
///
/// Returns null when there is nothing to restate, so the caller falls straight
/// through to the distribution rule.
Map<int, String>? rekeyWorkspaceMap(
  Map<int, String>? learned,
  List<MonitorTileData> mons,
) {
  if (learned == null || learned.isEmpty) return null;
  String? idFor(String target) {
    for (final m in mons) {
      if (m.id == target ||
          m.edidDescriptor == target ||
          m.manufacturer == target) {
        return m.id;
      }
    }
    return null;
  }

  final out = <int, String>{};
  for (final entry in learned.entries) {
    final id = idFor(entry.value);
    if (id != null) out[entry.key] = id;
  }
  return out.isEmpty ? null : out;
}

/// The screens of [profile] that can own workspaces: switched on, and not a
/// mirror destination showing someone else's picture.
List<MonitorTileData> _placeableScreens(Profile profile) => [
      for (final m in profile.monitors)
        if (m.enabled && m.mirrorOf == null) m,
    ];

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
    // Computed from EVERY remembered setup, not just the one in front of the
    // user, and deliberately not from the live outputs. See [workspaceHomes].
    homes: workspaceHomes(
      profiles: profiles,
      distribution: distribution,
      followProfileMap: followProfileMap,
      maxWorkspaces: maxWorkspaces,
    ),
  );
}
