import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/domain/workspace_layout.dart';

/// Where the repair chain leaves every screen once it has finished.
///
/// The chain has always put each workspace on the right screen. What it also
/// does — and what nothing tested — is decide what every screen is left
/// *showing*, because relocating a workspace means focusing it, and a screen
/// shows whichever of its workspaces was focused last. Walking 1..9 in
/// ascending order therefore ended each screen on the highest number it owns.
/// Those are the numbers nobody has anything open on, so a docked desk came
/// up with three blank workspaces in front of the user's windows; only the
/// screen the trailing hand-back focus happened to land on was right.
///
/// Measured on sway 1.12 — three screens, the interleaved rule, all nine
/// workspaces declared, the walk run by hand over the live compositor:
///
///     ascending 1..9,  then focus 3  ->  eDP-1: 7   DP-1: 8   HDMI-A-2: 3
///     descending 9..1, then focus 3  ->  eDP-1: 1   DP-1: 2   HDMI-A-2: 3
///
/// The empty high workspaces are garbage-collected as the descending walk
/// passes them, so the desk is left on the lowest number each screen owns —
/// which is where the open windows are.
void main() {
  group('the repair chain descends', () {
    test('the highest workspace is walked before the lowest', () {
      final chain = buildWorkspaceChain(_interleaved())!;
      expect(chain.indexOf('workspace number 9'),
          lessThan(chain.indexOf('workspace number 1')));
    });

    test('every home is still declared before anything is moved into it', () {
      final chain = buildWorkspaceChain(_interleaved())!;
      final statements = chain.split('; ');
      final lastDeclaration = statements
          .lastIndexWhere((s) => RegExp(r'^workspace \d+ output ').hasMatch(s));
      final firstFocus =
          statements.indexWhere((s) => s.startsWith('workspace number '));
      expect(lastDeclaration, lessThan(firstFocus));
    });

    test('the direction changed and the placement did not', () {
      final chain = buildWorkspaceChain(_interleaved())!;
      final moves = <int, String>{};
      final statements = chain.split('; ');
      for (var i = 0; i < statements.length - 1; i++) {
        final focus =
            RegExp(r'^workspace number (\d+)$').firstMatch(statements[i]);
        final move = RegExp(r"^move workspace to output '(.+)'$")
            .firstMatch(statements[i + 1]);
        if (focus != null && move != null) {
          moves[int.parse(focus.group(1)!)] = move.group(1)!;
        }
      }
      expect(moves, equals(_interleaved()));
    });

    test('the trailing hand-back still has the last word', () {
      final chain =
          buildWorkspaceChain(_interleaved(), returnFocusTo: 6)!;
      expect(chain.split('; ').last, equals('workspace number 6'));
    });

    test('with nothing to hand back to it lands on workspace 1', () {
      final chain = buildWorkspaceChain(_interleaved())!;
      expect(chain.split('; ').last, equals('workspace number 1'));
    });
  });

  group('what the desk looks like afterwards', () {
    test('each screen is left on the lowest workspace it owns', () {
      final desk = _Desk(
        outputs: const ['L', 'M', 'R'],
        homes: _interleaved(),
        open: const {1: 'L', 2: 'M', 3: 'R'},
      );
      desk.run(buildWorkspaceChain(_interleaved(), returnFocusTo: 1)!);
      expect(desk.showing, equals({'L': 1, 'M': 2, 'R': 3}));
    });

    test('the ascending walk is what left the high numbers on screen', () {
      // The old shape, spelled out here rather than produced, so this file
      // both states the bug and proves the model below can see it. Without
      // this the test above would pass against a simulator that simply never
      // moved anything.
      final desk = _Desk(
        outputs: const ['L', 'M', 'R'],
        homes: _interleaved(),
        open: const {1: 'L', 2: 'M', 3: 'R'},
      );
      desk.run(_ascending(_interleaved(), returnFocusTo: 1));
      expect(desk.showing, equals({'L': 1, 'M': 8, 'R': 9}));
    });

    test('a hand-back to a high number wins for its own screen only', () {
      final desk = _Desk(
        outputs: const ['L', 'M', 'R'],
        homes: _interleaved(),
        open: const {1: 'L', 2: 'M', 3: 'R'},
      );
      desk.run(buildWorkspaceChain(_interleaved(), returnFocusTo: 6)!);
      expect(desk.showing, equals({'L': 1, 'M': 2, 'R': 6}));
      expect(desk.focused, equals(6));
    });

    test('a workspace with windows on it survives the walk', () {
      final desk = _Desk(
        outputs: const ['L', 'M', 'R'],
        homes: _interleaved(),
        open: const {1: 'L', 4: 'L', 6: 'R'},
        withWindows: const {4, 6},
      );
      desk.run(buildWorkspaceChain(_interleaved(), returnFocusTo: 1)!);
      expect(desk.showing, equals({'L': 1, 'M': 2, 'R': 3}));
      expect(desk.where[4], equals('L'));
      expect(desk.where[6], equals('R'));
    });

    test('a workspace stranded on the wrong screen is brought home', () {
      final desk = _Desk(
        outputs: const ['L', 'M', 'R'],
        homes: _interleaved(),
        // Everything piled onto the laptop panel, which is what an undocked
        // boot followed by a dock actually looks like.
        open: const {1: 'L', 2: 'L', 3: 'L'},
        withWindows: const {1, 2, 3},
      );
      desk.run(buildWorkspaceChain(_interleaved(), returnFocusTo: 1)!);
      expect(desk.where[2], equals('M'));
      expect(desk.where[3], equals('R'));
      expect(desk.showing, equals({'L': 1, 'M': 2, 'R': 3}));
    });

    test('grouped bands land on the first number of each band', () {
      const grouped = {
        1: 'L',
        2: 'L',
        3: 'L',
        4: 'L',
        5: 'L',
        6: 'R',
        7: 'R',
        8: 'R',
        9: 'R',
      };
      final desk = _Desk(
        outputs: const ['L', 'R'],
        homes: grouped,
        open: const {1: 'L', 2: 'R'},
      );
      desk.run(buildWorkspaceChain(grouped, returnFocusTo: 1)!);
      expect(desk.showing, equals({'L': 1, 'R': 6}));
    });

    test('one screen still ends on workspace 1', () {
      const solo = {1: 'L', 2: 'L', 3: 'L'};
      final desk = _Desk(
        outputs: const ['L'],
        homes: solo,
        open: const {1: 'L'},
      );
      desk.run(buildWorkspaceChain(solo)!);
      expect(desk.showing, equals({'L': 1}));
    });
  });
}

/// The reporter's desk: laptop, ultrawide, portrait panel, interleaved.
Map<int, String> _interleaved() => {
      for (var ws = 1; ws <= 9; ws++) ws: const ['L', 'M', 'R'][(ws - 1) % 3],
    };

/// The chain as it was built before this change: the same declarations and
/// the same moves, walked the other way round.
String _ascending(Map<int, String> map, {int? returnFocusTo}) {
  final numbers = map.keys.toList()..sort();
  final parts = <String>[
    buildWorkspaceDeclarations(homesFromMap(map))!,
  ];
  for (final ws in numbers) {
    parts.add('workspace number $ws');
    parts.add("move workspace to output '${map[ws]}'");
  }
  parts.add('workspace number ${returnFocusTo ?? numbers.first}');
  return parts.join('; ');
}

/// A desk, with the two rules of sway's that decide what stays on screen.
///
/// Not a compositor. It models exactly what the measurement above turned on
/// and nothing else:
///
///   * every screen shows exactly one workspace, and it is the one focused
///     there most recently;
///   * a workspace that stops being shown and has no windows on it is
///     destroyed, and a screen left with none gets a fresh one — sway's
///     `workspace_next_name`, reduced to "the lowest free number".
///
/// Focusing a workspace that does not exist creates it on the screen its
/// binding names, which is the third rule and the reason the declarations
/// have to come first.
class _Desk {
  _Desk({
    required List<String> outputs,
    required this.homes,
    required Map<int, String> open,
    Set<int> withWindows = const {},
  })  : where = Map.of(open),
        windows = Set.of(withWindows),
        showing = {} {
    for (final output in outputs) {
      final here = where.entries.where((e) => e.value == output).map((e) => e.key);
      showing[output] = here.isEmpty ? _born(output) : here.reduce((a, b) => a < b ? a : b);
    }
    focused = showing[outputs.first]!;
  }

  /// Where each workspace lives.
  final Map<int, String> where;

  /// Which of them are not empty, and therefore cannot be collected.
  final Set<int> windows;

  /// What each screen is displaying.
  final Map<String, int> showing;

  /// Where a workspace is born when it does not exist yet.
  final Map<int, String> homes;

  late int focused;

  void run(String chain) {
    for (final statement in chain.split('; ')) {
      _step(statement.trim());
    }
  }

  void _step(String statement) {
    if (RegExp(r'^workspace \d+ output ').hasMatch(statement)) return;

    final focus = RegExp(r'^workspace number (\d+)$').firstMatch(statement);
    if (focus != null) {
      final ws = int.parse(focus.group(1)!);
      where[ws] ??= homes[ws] ?? where[focused]!;
      _show(where[ws]!, ws);
      focused = ws;
      return;
    }

    final move =
        RegExp(r"^move workspace to output '(.+)'$").firstMatch(statement);
    if (move == null) return;
    final to = move.group(1)!;
    final from = where[focused]!;
    if (from == to) return;
    where[focused] = to;
    _show(to, focused);
    // The screen it just left needs something to display. sway auto-creates
    // one when nothing is left there.
    final left = where.entries.where((e) => e.value == from).map((e) => e.key);
    showing[from] =
        left.isEmpty ? _born(from) : left.reduce((a, b) => a < b ? a : b);
  }

  /// Puts [ws] on [output] and collects whatever it displaced, if empty.
  void _show(String output, int ws) {
    final was = showing[output];
    showing[output] = ws;
    if (was != null && was != ws && !windows.contains(was)) where.remove(was);
  }

  /// The lowest number nothing is using, created on [output].
  int _born(String output) {
    var ws = 1;
    while (where.containsKey(ws)) {
      ws++;
    }
    where[ws] = output;
    return ws;
  }
}
