import 'package:kanshi_gui/models/monitor_tile_data.dart';

// What happens to the built-in screen when the laptop lid closes.
//
// kanshi cannot answer this. It picks a profile from the screens that are
// CONNECTED, and closing the lid disconnects nothing: the panel stays plugged
// in, goes dark, and keeps its place in the layout — workspaces on it, the
// pointer able to wander onto it. Two profiles ("lid open", "lid closed")
// would not help either, because to kanshi both describe the same hardware.
//
// So the lid is not a profile, it is a rule applied on top of whichever
// profile kanshi chose: with the lid closed, the panel is switched off, as
// long as another screen is there to take over. sway reports the lid through
// a `bindswitch`, and kanshi's own `exec` covers the case a binding cannot —
// kanshi re-applying its profile (a screen plugged in, a save in the app)
// switches the panel back on while the lid is still closed.
//
// Everything here is pure. The helper binary owns the I/O; the tests own the
// cases.

/// The laptop lid, as far as anything here can tell.
enum LidState {
  open,
  closed,

  /// Nothing reports a lid — a desktop, or hardware without ACPI's lid
  /// button. Never acted on.
  unknown;

  /// The word sway's binding passes (`--lid closed`), or null.
  static LidState? fromArgument(String? raw) => switch (raw) {
        'open' => LidState.open,
        'closed' => LidState.closed,
        _ => null,
      };

  /// Reads `/proc/acpi/button/lid/*/state`, which says `state:      open`.
  static LidState fromAcpi(String raw) {
    final word = raw.split(':').last.trim().toLowerCase();
    return switch (word) {
      'open' => LidState.open,
      'closed' => LidState.closed,
      _ => LidState.unknown,
    };
  }
}

/// What asked for a decision.
enum LidTrigger {
  /// sway's `bindswitch` fired: the lid just moved.
  lidMoved,

  /// kanshi just applied a profile. Whatever it switched on or off is what
  /// the profile wants, so nothing remembered from before still holds.
  profileApplied,
}

/// The connector names of built-in panels: `eDP-1`, `LVDS-1`, `DSI-1`.
///
/// Deliberately strict. A connector that matches goes into a sway command,
/// and every name this accepts is plain ASCII with no space or quote in it.
final _builtInPanel = RegExp(r'^(?:eDP|LVDS|DSI)-[A-Za-z0-9-]+$');

bool isBuiltInPanel(String connector) => _builtInPanel.hasMatch(connector);

/// What to switch, and what to remember.
class LidDecision {
  /// Panels to switch off.
  final List<String> switchOff;

  /// Panels to switch back on.
  final List<String> switchOn;

  /// The panels that are off because of the lid, and only because of it,
  /// once [switchOff] and [switchOn] have gone through. These — and nothing
  /// else — come back on when the lid opens.
  final Set<String> switchedOff;

  /// One line for the journal.
  final String reason;

  const LidDecision(this.reason, this.switchedOff,
      {this.switchOff = const [], this.switchOn = const []});

  bool get changesAnything => switchOff.isNotEmpty || switchOn.isNotEmpty;

  /// The sway command for one panel. Safe to send as is: [isBuiltInPanel]
  /// admits no space, quote or separator.
  static String command(String panel, {required bool on}) =>
      'output $panel ${on ? 'enable' : 'disable'}';
}

/// Decides what the lid means for the screens in [live].
///
/// [switchedOff] is what an earlier decision turned off. [mirrorDestinations]
/// are screens showing another screen's picture: they are not "another screen
/// to take over", and a panel being mirrored onto a projector must stay on or
/// the projector shows nothing.
///
/// The rules, each of which is a promise to the user:
///
///  * Closed: panels go off only while another screen of its own is on. A
///    lid closed on a laptop alone never leaves the session without a screen
///    — suspend is logind's call, not this one.
///  * Open: only what the lid turned off comes back. A panel the profile
///    itself switched off is the user's choice and stays off.
///  * Unknown: nothing happens.
LidDecision decideLid({
  required LidState lid,
  required LidTrigger trigger,
  required List<MonitorTileData> live,
  Set<String> switchedOff = const {},
  Set<String> mirrorDestinations = const {},
}) {
  final panels = [
    for (final m in live)
      if (isBuiltInPanel(m.id)) m,
  ];
  // After kanshi applied a profile, every panel is in the state the profile
  // asked for. A record from before that is stale: honouring it would switch
  // on, at the next lid opening, a panel the new profile wants off.
  final remembered = trigger == LidTrigger.profileApplied
      ? <String>{}
      : {
          for (final p in panels)
            if (!p.enabled && switchedOff.contains(p.id)) p.id,
        };
  if (panels.isEmpty) {
    return LidDecision('no built-in screen', remembered);
  }

  switch (lid) {
    case LidState.unknown:
      return LidDecision('lid state unknown', remembered);
    case LidState.open:
      if (trigger == LidTrigger.profileApplied) {
        return const LidDecision('lid open', {});
      }
      final back = [
        for (final p in panels)
          if (remembered.contains(p.id)) p.id,
      ];
      return LidDecision(
        back.isEmpty
            ? 'lid opened; nothing was switched off for it'
            : 'lid opened; switching ${back.join(', ')} back on',
        const {},
        switchOn: back,
      );
    case LidState.closed:
      final on = [
        for (final p in panels)
          if (p.enabled) p.id,
      ];
      if (on.isEmpty) {
        return LidDecision('lid closed; panel already off', remembered);
      }
      final others = [
        for (final m in live)
          if (m.enabled &&
              !isBuiltInPanel(m.id) &&
              !mirrorDestinations.contains(m.id))
            m.id,
      ];
      if (others.isEmpty) {
        return LidDecision(
          'lid closed, but no other screen is on; leaving ${on.join(', ')} on',
          remembered,
        );
      }
      return LidDecision(
        'lid closed; switching ${on.join(', ')} off, '
        '${others.join(', ')} ${others.length == 1 ? 'takes' : 'take'} over',
        {...remembered, ...on},
        switchOff: on,
      );
  }
}
