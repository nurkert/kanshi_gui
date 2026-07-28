import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/state/history_stack.dart';

MonitorTileData _mon({String id = 'A', double x = 0}) => MonitorTileData(
      id: id,
      manufacturer: id,
      x: x,
      y: 0,
      width: 1920,
      height: 1080,
      rotation: 0,
      refresh: 60,
      resolution: '1920x1080',
      orientation: 'landscape',
    );

List<Profile> _profiles(double x) =>
    [Profile(name: 'P', monitors: [_mon(x: x)])];

void main() {
  test('undo returns the state recorded before the mutation', () {
    final h = HistoryStack();
    final live = _profiles(0);
    h.push(live, 0, 'move A');
    live.single.monitors[0] = _mon(x: 500);

    final entry = h.undo(HistoryStack.snapshot(live, 0, ''));
    expect(entry, isNotNull);
    expect(entry!.profiles.single.monitors.single.x, 0);
    expect(entry.label, 'move A');
  });

  test('redo replays the state undo walked away from', () {
    final h = HistoryStack();
    var live = _profiles(0);
    h.push(live, 0, 'move A');
    live = _profiles(500);

    final undone = h.undo(HistoryStack.snapshot(live, 0, ''))!;
    expect(undone.profiles.single.monitors.single.x, 0);

    final redone = h.redo(HistoryStack.snapshot(undone.profiles, 0, ''))!;
    expect(redone.profiles.single.monitors.single.x, 500);
    expect(redone.label, 'move A',
        reason: 'redo names the step it replays, not the state it came from');
  });

  test('a snapshot does not alias the live profiles', () {
    // Profile is mutable. Handing out the same list would let a later edit
    // rewrite history in place, so undo would return the user to the state
    // they were trying to leave.
    final h = HistoryStack();
    final live = _profiles(0);
    h.push(live, 0, 'move A');
    live.single.monitors[0] = _mon(x: 900);
    live.single.name = 'renamed after the fact';

    final entry = h.undo(HistoryStack.snapshot(live, 0, ''))!;
    expect(entry.profiles.single.monitors.single.x, 0);
    expect(entry.profiles.single.name, 'P');
  });

  test('overrides record the pre-drag tile, not the mid-drag one', () {
    // By the time a drag commits, the profile already holds mid-drag
    // positions. Without the override, undo would return the user to the last
    // frame of their own drag instead of where they started.
    final h = HistoryStack();
    final midDrag = _profiles(480);
    h.push(midDrag, 0, 'move A', overrides: {'A': _mon(x: 0)});

    final entry = h.undo(HistoryStack.snapshot(midDrag, 0, ''))!;
    expect(entry.profiles.single.monitors.single.x, 0);
  });

  test('a fresh mutation makes the redo branch unreachable', () {
    final h = HistoryStack();
    h.push(_profiles(0), 0, 'first');
    h.undo(HistoryStack.snapshot(_profiles(1), 0, ''));
    expect(h.canRedo, isTrue);

    h.push(_profiles(2), 0, 'second');
    expect(h.canRedo, isFalse);
  });

  test('both stacks stay bounded', () {
    final h = HistoryStack(cap: 3);
    for (var i = 0; i < 10; i++) {
      h.push(_profiles(i.toDouble()), 0, 'step $i');
    }
    // The oldest entries are dropped, so the deepest undo available is the
    // state before step 7, not step 0.
    expect(h.nextUndoLabel, 'step 9');
    var count = 0;
    while (h.canUndo) {
      h.undo(HistoryStack.snapshot(_profiles(0), 0, ''));
      count++;
    }
    expect(count, 3);
  });

  test('empty stacks report nothing to do', () {
    final h = HistoryStack();
    expect(h.canUndo, isFalse);
    expect(h.nextUndoLabel, isNull);
    expect(h.undo(HistoryStack.snapshot(_profiles(0), 0, '')), isNull);
    expect(h.redo(HistoryStack.snapshot(_profiles(0), 0, '')), isNull);
  });
}
