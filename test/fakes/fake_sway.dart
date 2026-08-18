import 'dart:async';

import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/workspace_daemon_core.dart';

/// A sway that answers commands with the events the real one answers them
/// with.
///
/// The point is the answering. A fake that only records commands cannot see
/// the bug that mattered: the helper relocated a workspace, and relocating
/// means focusing, and focusing away leaves the previous one empty, and sway
/// collects an empty workspace, and the next command recreates it. The loop
/// only exists because sway talks back — so this one talks back.
///
/// Modelled on a transcript captured from the live incident:
///
///     init  ws=1 -> eDP-1
///     move  ws=1 -> DP-4
///     empty ws=1 -> DP-4
///     init  ws=1 -> eDP-1      … 65 times in three seconds
class FakeSway implements SwayConnection {
  FakeSway({
    required this.live,
    Map<int, String>? workspaces,
    this.focused,
  }) : _workspaces = Map.of(workspaces ?? const {});

  final List<MonitorTileData> live;
  final Map<int, String> _workspaces;
  int? focused;

  /// Where sway thinks each workspace should be BORN, and the shape of the
  /// bug this whole feature had.
  ///
  /// sway's `cmd_workspace` appends to this list and never clears it, and
  /// `workspace_get_initial_output` takes the first entry that resolves to a
  /// connected screen — so the first binding a session is given wins for the
  /// rest of that session and every later one is a silent no-op. Measured on
  /// sway 1.12: declare `workspace 5 output A`, then `workspace 5 output B`,
  /// then create workspace 5, and it is born on A.
  ///
  /// Modelling it here is what lets a test reproduce a docked laptop: boot
  /// undocked, the laptop-only setup binds all nine workspaces to the panel,
  /// dock, the docked setup binds them to the external screens behind it —
  /// and every workspace opened from then on is still born on the panel.
  final Map<int, List<String>> bindings = {};

  /// Every command the helper sent, in order.
  final List<String> commands = [];

  final _events = StreamController<Map<String, dynamic>>.broadcast();

  /// Whether the fake answers a focus-and-move chain with the workspace
  /// churn the real compositor produces. On by default — that churn IS the
  /// hazard under test.
  bool echoChurn = true;

  @override
  Stream<Map<String, dynamic>> events() => _events.stream;

  @override
  Future<List<MonitorTileData>> outputs() async => live;

  @override
  Future<Map<int, String>> workspaceOutputs() async => Map.of(_workspaces);

  @override
  Future<int?> focusedWorkspace() async => focused;

  @override
  Future<bool> run(String command) async {
    commands.add(command);
    if (!echoChurn) return true;
    // A chain arrives as one string and sway executes it step by step,
    // answering each step. Splitting here is what makes the difference
    // between the two shapes visible: the focus-and-move chain focuses nine
    // workspaces and therefore emits nine `focus` events, while a bare
    // `move workspace to output` focuses nothing and emits none.
    for (final part in command.split(';')) {
      _step(part.trim());
    }
    return true;
  }

  /// One sway command, and the events sway answers it with.
  ///
  /// Modelled on sway 1.12, measured rather than assumed:
  ///
  ///   * `workspace N output A B …` is a declaration. It emits nothing and
  ///     moves nothing; it only says where N will be BORN, and sway keeps the
  ///     first such binding it is ever given.
  ///   * `workspace [number] N` focuses N, creating it if it does not exist,
  ///     and leaves the previous one empty — which sway then collects.
  ///   * `move workspace to output X` relocates the FOCUSED workspace. It
  ///     emits `move`, and an `init` for the workspace sway auto-creates on
  ///     the screen just vacated — unfocused. It does NOT emit `focus`, and
  ///     that is precisely why a correction cannot answer itself.
  void _step(String part) {
    final decl =
        RegExp(r'^workspace (?:number )?(\d+) output (.+)$').firstMatch(part);
    if (decl != null) {
      // Appended, never replaced. See [bindings].
      bindings
          .putIfAbsent(int.parse(decl.group(1)!), () => <String>[])
          .addAll(_targets(decl.group(2)!));
      return;
    }

    final focus = RegExp(r'^workspace (?:number )?(\d+)$').firstMatch(part);
    if (focus != null) {
      final ws = int.parse(focus.group(1)!);
      final was = focused;
      if (!_workspaces.containsKey(ws)) {
        _workspaces[ws] = _birthplaceOf(ws);
        _emit(_ws('init', ws, focused: false));
      }
      focused = ws;
      _emit(_ws('focus', ws, focused: true));
      if (was != null && was != ws && _workspaces.containsKey(was)) {
        _emit(_ws('empty', was, focused: false));
        _workspaces.remove(was);
      }
      return;
    }

    final move =
        RegExp("^move workspace to output '?(.*?)'?\$").firstMatch(part);
    if (move == null) return;
    final ws = focused;
    if (ws == null || !_workspaces.containsKey(ws)) return;
    final from = _workspaces[ws];
    final to = _resolve(move.group(1)!);
    if (to == null || to == from) return;
    _workspaces[ws] = to;
    _emit(_ws('move', ws, focused: false));
    if (from != null && !_workspaces.containsValue(from)) {
      var fresh = 1;
      while (_workspaces.containsKey(fresh)) {
        fresh++;
      }
      _workspaces[fresh] = from;
      _emit(_ws('init', fresh, focused: false));
    }
  }

  /// Where a workspace that does not exist yet is created: the first binding
  /// that resolves to a connected screen, and otherwise the screen the user is
  /// looking at — `workspace_get_initial_output`, as sway implements it.
  String _birthplaceOf(int ws) {
    for (final target in bindings[ws] ?? const <String>[]) {
      final resolved = _resolve(target);
      if (resolved != null) return resolved;
    }
    final here = focused == null ? null : _workspaces[focused];
    return here ?? (live.isEmpty ? 'unknown' : live.first.id);
  }

  /// The output targets of one declaration: `'A' 'B'`, or bare words.
  static List<String> _targets(String rest) => [
        for (final m in RegExp(r"'([^']*)'|(\S+)").allMatches(rest))
          m.group(1) ?? m.group(2)!,
      ];

  /// A connector name, or the EDID descriptor of one of the live screens.
  String? _resolve(String target) {
    for (final m in live) {
      if (m.id == target || m.edidDescriptor == target) return m.id;
    }
    return null;
  }

  Map<String, dynamic> _ws(String change, int ws, {required bool focused}) => {
        'change': change,
        'current': {
          'num': ws,
          'name': '$ws',
          'output': _workspaces[ws],
          'focused': focused,
        },
      };

  void _emit(Map<String, dynamic> event) {
    scheduleMicrotask(() {
      if (!_events.isClosed) _events.add(event);
    });
  }

  /// A screen appeared or disappeared. The payload is what a live sway
  /// actually sends — nothing but a change, and the change is always
  /// "unspecified".
  void hotplug() => _emit({'change': 'unspecified'});

  /// `swaymsg reload`, which discards every workspace config sway holds.
  void reload() => _emit({'change': 'reload'});

  /// The user pressing \$mod+N, with sway deciding where the workspace lands
  /// if it does not exist yet — which is the whole point: a stale binding puts
  /// it on last week's screen and nothing in the config file can say otherwise.
  void userSwitchedTo(int workspace, [String? output]) {
    final born = !_workspaces.containsKey(workspace);
    _workspaces[workspace] = output ?? _birthplaceOf(workspace);
    if (born) _emit(_ws('init', workspace, focused: false));
    focused = workspace;
    _emit(_ws('focus', workspace, focused: true));
  }

  Future<void> dispose() => _events.close();
}

/// The two files, in memory.
class FakeEnvironment implements DaemonEnvironment {
  FakeEnvironment({
    required this.mode,
    required this.knownProfiles,
    this.marker,
  });

  WorkspaceManagementMode mode;
  List<Profile> knownProfiles;
  String? marker;

  @override
  Future<AppSettings> settings() async =>
      AppSettings(filePath: '/dev/null')..workspaceManagement = mode;

  @override
  Future<List<Profile>> profiles() async => knownProfiles;

  @override
  Future<String?> markedProfile() async => marker;
}
