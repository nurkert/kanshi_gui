// A repair that did not take, and the helper noticing.
//
// Reported as "it silently stopped working": for a week every dock put the
// workspaces right, then it did not, and the journal had nothing to say. A
// repair is a chain of `move workspace to output X`, and sway refuses a move
// onto a screen it has not switched on yet — which is where a dock is a
// second and a half in, while kanshi is still setting modes. The moves are
// dropped, the desk stays wrong, and nothing retried.

import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/workspace_daemon_core.dart';

import 'fakes/fake_sway.dart';

MonitorTileData _mon(String id, double x) => MonitorTileData(
      id: id,
      manufacturer: 'Panel $id',
      edidDescriptor: 'Make $id Serial$id',
      x: x,
      y: 0,
      width: 2560,
      height: 1440,
      scale: 1.0,
      rotation: 0,
      refresh: 60,
      resolution: '2560x1440',
      orientation: 'landscape',
      enabled: true,
    );

List<MonitorTileData> desk() =>
    [_mon('DP-4', 0), _mon('DP-5', 2560), _mon('eDP-1', 5120)];

void main() {
  late FakeSway sway;
  late FakeEnvironment env;
  late List<String> log;
  late WorkspaceDaemonCore core;

  setUp(() {
    // echoChurn off: commands are recorded and nothing moves — the shape of
    // a sway that dropped every move because the screens were not on yet.
    sway = FakeSway(
      live: desk(),
      workspaces: {1: 'eDP-1', 2: 'eDP-1', 6: 'eDP-1'},
      focused: 6,
    )..echoChurn = false;
    env = FakeEnvironment(
      mode: WorkspaceManagementMode.interleaved,
      knownProfiles: [Profile(name: 'Office', monitors: desk())],
    );
    log = [];
    core = WorkspaceDaemonCore(sway: sway, env: env, log: log.add);
  });

  tearDown(() => sway.dispose());

  /// The desk as the repair would have left it had sway obeyed.
  void deskIsRight() {
    sway
      ..userSwitchedTo(1, 'DP-4')
      ..userSwitchedTo(2, 'DP-5')
      ..userSwitchedTo(6, 'eDP-1');
  }

  test('a repair that took is verified and left alone', () async {
    await core.apply(ApplyReason.outputsChanged);
    expect(sway.commands, hasLength(1));
    deskIsRight();

    expect(await core.verifyRepair(), isFalse);
    expect(sway.commands, hasLength(1));
    expect(log.last, contains('verified'));
  });

  test('a repair sway dropped is sent again, and said so', () async {
    await core.apply(ApplyReason.outputsChanged);
    expect(sway.commands, hasLength(1));
    expect(await sway.workspaceOutputs(), {1: 'eDP-1', 2: 'eDP-1', 6: 'eDP-1'},
        reason: 'nothing moved');

    expect(await core.verifyRepair(), isTrue);
    expect(sway.commands, hasLength(2), reason: 'repaired again');
    expect(log.any((l) => l.contains('repair did not take')), isTrue);
    expect(log.any((l) => l.contains('1 on eDP-1, wanted DP-4')), isTrue);

    // The screens come on and the second repair lands; the next look finds
    // the desk right.
    deskIsRight();
    expect(await core.verifyRepair(), isFalse);
    expect(log.last, contains('verified'));
  });

  test('it gives up after the ceiling instead of hammering the desk',
      () async {
    await core.apply(ApplyReason.outputsChanged);
    for (var i = 0; i < WorkspaceDaemonCore.repairRetryCeiling; i++) {
      expect(await core.verifyRepair(), isTrue);
    }
    final sentSoFar = sway.commands.length;
    expect(sentSoFar, 1 + WorkspaceDaemonCore.repairRetryCeiling);
    expect(await core.verifyRepair(), isFalse);
    expect(sway.commands, hasLength(sentSoFar));
    expect(log.last, contains('leaving it until the next screen change'));
  });

  test('a workspace the user moved by hand is not counted as wrong', () async {
    await core.apply(ApplyReason.outputsChanged);
    // Workspaces 1 and 2 are theirs now; 6 is on its screen already.
    expect(core.noteMove(1, 'eDP-1'), isTrue);
    expect(core.noteMove(2, 'eDP-1'), isTrue);
    expect(await core.verifyRepair(), isFalse);
    expect(sway.commands, hasLength(1));
    expect(log.last, contains('verified'));
  });

  test('a new placement starts the retry budget afresh', () async {
    await core.apply(ApplyReason.outputsChanged);
    for (var i = 0; i < WorkspaceDaemonCore.repairRetryCeiling; i++) {
      await core.verifyRepair();
    }
    expect(await core.verifyRepair(), isFalse, reason: 'budget spent');

    // A different desk: the laptop alone.
    env.knownProfiles.add(Profile(name: 'Train', monitors: [_mon('eDP-1', 0)]));
    sway.live
      ..clear()
      ..add(_mon('eDP-1', 0));
    await core.apply(ApplyReason.outputsChanged);
    // Everything belongs on eDP-1 there, and everything is: verified, and
    // the budget is back for the next dock.
    expect(await core.verifyRepair(), isFalse);
    expect(log.last, contains('verified'));
  });
}
