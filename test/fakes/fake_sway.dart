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

    // A chain that focuses and moves. Real sway emits, per workspace: init
    // (if it had to create it), focus, move, and empty for the one left
    // behind. Emitted asynchronously, exactly as they arrive over the socket.
    if (command.contains('move workspace to output')) {
      for (final entry in _workspaces.entries) {
        _emit({
          'change': 'focus',
          'current': {'num': entry.key, 'output': entry.value},
        });
        _emit({
          'change': 'move',
          'current': {'num': entry.key, 'output': entry.value},
        });
        _emit({
          'change': 'empty',
          'current': {'num': entry.key, 'output': entry.value},
        });
        _emit({
          'change': 'init',
          'current': {'num': entry.key, 'output': entry.value},
        });
      }
    }
    return true;
  }

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

  /// The user pressing $mod+N.
  void userSwitchedTo(int workspace, String output) {
    _workspaces[workspace] = output;
    focused = workspace;
    _emit({
      'change': 'focus',
      'current': {'num': workspace, 'output': output},
    });
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
