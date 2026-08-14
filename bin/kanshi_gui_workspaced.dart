// The workspace helper.
//
// kanshi already re-applies the `exec swaymsg "…"` chain on every profile
// activation, and the GUI repairs the placement when you open it. Between
// those two there is a gap, and it is the gap people actually live in:
//
//   * `kanshi(5)` says exec commands "are executed asynchronously and their
//     order may not be preserved", so on a cold boot that chain races sway's
//     output discovery. An output sway does not know by name yet has its
//     `output 'X'` target dropped without an error, and the workspaces land
//     wherever they were created.
//   * sway's `cmd_workspace` APPENDS to a workspace's output list and never
//     clears it, and `workspace_get_initial_output` takes the first entry
//     that resolves. So a workspace bound to the laptop panel before you
//     docked stays on the laptop panel for the rest of the session, however
//     often the correct binding is declared afterwards.
//
// Neither is fixable from a config file. Both are trivial for something that
// is *there* — watching, with the answer already computed. This binary is
// that: it re-applies on every hotplug, re-declares after a `swaymsg reload`
// wipes the workspace configs, and moves each workspace as it is created if
// sway put it somewhere else.
//
// It is a separate executable rather than a mode of the GUI because a Flutter
// binary drags a GTK window and a rendering engine behind it. Compiled from
// the same domain code the app uses, so the two cannot disagree about where
// workspace 9 belongs.
//
// Opt-in, per user, and off until someone turns it on: see WorkspaceDaemon.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kanshi_gui/domain/output_identity.dart';
import 'package:kanshi_gui/domain/workspace_plan.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';

/// How long the output set must stay unchanged before the placement is
/// re-applied. Docking is a salvo, not an event: outputs appear one at a time
/// as the dock enumerates them and EDID settles late, and kanshi needs its
/// own moment to switch profiles afterwards. Acting on the first event would
/// compute an answer for half a desk.
const _settle = Duration(milliseconds: 1500);

/// Sway is not necessarily up when the user session is. Rather than failing
/// and leaving `systemctl --user status` showing a dead unit, wait — this is
/// a service whose whole job is to be there before the user needs it.
const _swayPoll = Duration(seconds: 3);

Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }
  final once = args.contains('--once');
  final dryRun = args.contains('--dry-run');
  // A dry run that says nothing is a dry run that answers nothing.
  final verbose =
      dryRun || args.contains('--verbose') || args.contains('-v');

  final daemon = _Daemon(verbose: verbose, dryRun: dryRun);
  if (once) {
    final sock = await _findSocket();
    if (sock == null) {
      stderr.writeln('kanshi-gui-workspaced: no sway socket found.');
      exitCode = 1;
      return;
    }
    await daemon.attach(sock);
    await daemon.apply(force: true);
    return;
  }
  await daemon.run();
}

const _usage = '''
kanshi-gui-workspaced — keeps sway workspaces on the screens kanshi_gui
remembers, at login, on every hotplug, and as each workspace opens.

  --once      apply the current setup's placement and exit
  --dry-run   work out the placement and print it, changing nothing
  -v          log what it decides
  -h          this text

Reads ~/.config/kanshi-gui/settings.json and the kanshi config. Does nothing
at all unless workspace placement is switched on in kanshi_gui.
''';

class _Daemon {
  final bool verbose;

  /// Works everything out and sends nothing. The one honest way to answer
  /// "what would this do to my desk" without doing it.
  final bool dryRun;

  _Daemon({required this.verbose, this.dryRun = false});

  String? _sock;
  Timer? _settleTimer;

  /// The placement in force, kept between events so a workspace-init can be
  /// answered without re-reading two files and asking sway for its outputs.
  WorkspacePlan? _plan;

  void _log(String message) {
    if (verbose) stdout.writeln('kanshi-gui-workspaced: $message');
  }

  Future<void> attach(String sock) async => _sock = sock;

  Future<void> run() async {
    // One process, many sway sessions: a user who logs out and back in keeps
    // the same systemd user manager, so the loop outlives any single socket.
    while (true) {
      final sock = await _findSocket();
      if (sock == null) {
        await Future<void>.delayed(_swayPoll);
        continue;
      }
      _sock = sock;
      _log('attached to $sock');
      await _session();
      _log('sway went away');
      _settleTimer?.cancel();
      _plan = null;
    }
  }

  /// Follows one sway session until its socket closes.
  Future<void> _session() async {
    await apply(force: true);
    final proc = await Process.start(
      'swaymsg',
      ['-t', 'subscribe', '-m', '["output","workspace"]'],
      environment: {'SWAYSOCK': _sock!},
    );
    final done = Completer<void>();
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onEvent, onDone: () {
      if (!done.isCompleted) done.complete();
    }, onError: (Object _) {
      if (!done.isCompleted) done.complete();
    });
    // Drained so a chatty swaymsg cannot fill its pipe buffer and wedge.
    proc.stderr.drain<void>().ignore();
    await done.future;
    await proc.exitCode;
  }

  void _onEvent(String line) {
    Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final verdict = classifySwayEvent(event);
    switch (verdict.action) {
      case SwayEventAction.none:
        return;
      case SwayEventAction.replan:
        // Docking is a salvo, not an event. Coalesce it, and let kanshi
        // finish switching profiles before asking what the desk looks like.
        _settleTimer?.cancel();
        _settleTimer = Timer(_settle, () => unawaited(apply(force: true)));
        return;
      case SwayEventAction.placeOne:
        unawaited(_place(verdict.workspace!, verdict.on));
        return;
    }
  }

  Future<void> _place(int workspace, String? on) async {
    final plan = _plan;
    if (plan == null) return;
    final want = plan.map[workspace];
    if (want == null || on == null || on == want) return;
    final command = plan.moveOne(workspace);
    if (command == null) return;
    _log('workspace $workspace opened on $on, belongs on $want');
    if (dryRun) return;
    await _swaymsg([command]);
  }

  /// Recomputes the placement from the files and the live outputs, and hands
  /// it to sway.
  ///
  /// Everything is re-read every time. The settings and the config are small,
  /// this runs on a hotplug rather than on a frame, and re-reading is what
  /// makes the switch in the GUI take effect without restarting the service.
  Future<void> apply({bool force = false}) async {
    final settings = await AppSettings.load();
    final mode = settings.workspaceManagement;
    if (!mode.enabled) {
      _plan = null;
      _log('placement is switched off');
      return;
    }

    final live = await _liveOutputs();
    if (live.isEmpty) return;

    final profiles = await _profiles(settings);
    if (profiles.isEmpty) return;

    final plan = planWorkspaces(
      profiles: profiles,
      live: live,
      distribution: mode.distribution,
      followProfileMap: mode.followsMap,
      preferProfileName: await _markedProfile(),
    );
    if (plan == null) {
      _plan = null;
      _log('no remembered setup matches these screens');
      return;
    }
    _plan = plan;

    // Which half runs is the difference between invisible and disruptive.
    // Declaring costs nothing and touches nothing that exists; the focus-and-
    // move pass walks all nine workspaces and is very much visible, so it
    // only runs when the live layout actually disagrees.
    final actual = await _workspaceOutputs();
    final wrong = actual.entries.any((e) {
      final want = plan.map[e.key];
      return want != null && want != e.value;
    });
    final command = wrong ? plan.chain : plan.declarations;
    if (command == null) return;
    _log('${plan.profile.name}: ${wrong ? 'repairing' : 'declaring'} '
        '${plan.map.entries.map((e) => '${e.key}→${e.value}').join(' ')}');
    if (dryRun) {
      _log('would send: $command');
      return;
    }
    await _swaymsg([command]);
  }

  // ── Files ──────────────────────────────────────────────────────────────

  Future<List<Profile>> _profiles(AppSettings settings) async {
    final path = settings.kanshiConfigPath?.isNotEmpty == true
        ? settings.kanshiConfigPath!
        : '${Platform.environment['HOME']}/.config/kanshi/config';
    try {
      return KanshiConfigParser.parse(await File(path).readAsString());
    } catch (e) {
      _log('cannot read $path: $e');
      return const [];
    }
  }

  /// The profile kanshi says it activated. A hint, never an instruction —
  /// see [matchProfile]. Absent unless the user has the marker switched on.
  Future<String?> _markedProfile() async {
    try {
      final f = File('${Platform.environment['HOME']}/.current_kanshi_profile');
      if (!await f.exists()) return null;
      final name = (await f.readAsString()).trim();
      return name.isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }

  // ── sway ───────────────────────────────────────────────────────────────

  Future<List<MonitorTileData>> _liveOutputs() async {
    final raw = await _swaymsg(['-t', 'get_outputs']);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final o in list.cast<Map<String, dynamic>>())
          if ((o['name'] ?? '').toString().trim().isNotEmpty)
            _output(o),
      ];
    } catch (e) {
      _log('cannot read outputs: $e');
      return const [];
    }
  }

  /// Only the four fields the plan needs: who this screen is, and what it is
  /// plugged into. Geometry comes from the remembered setup, which is the
  /// whole point — the live positions are what the app is there to correct.
  MonitorTileData _output(Map<String, dynamic> o) {
    String clean(Object? raw) {
      final s = (raw ?? '').toString().trim();
      return s.toLowerCase() == 'unknown' ? '' : s;
    }

    final label = [clean(o['make']), clean(o['model']), clean(o['serial'])]
        .where((s) => s.isNotEmpty)
        .join(' ');
    return MonitorTileData(
      id: o['name'].toString().trim(),
      manufacturer: label,
      edidDescriptor: composeKanshiDescriptor(
            make: (o['make'] ?? '').toString(),
            model: (o['model'] ?? '').toString(),
            serial: (o['serial'] ?? '').toString(),
          ) ??
          '',
      x: 0,
      y: 0,
      width: 0,
      height: 0,
      rotation: 0,
      refresh: 60,
      resolution: '',
      orientation: 'landscape',
      enabled: o['active'] == true,
    );
  }

  Future<Map<int, String>> _workspaceOutputs() async {
    final raw = await _swaymsg(['-t', 'get_workspaces']);
    if (raw == null) return const {};
    try {
      final list = jsonDecode(raw) as List;
      return {
        for (final w in list.cast<Map<String, dynamic>>())
          if (w['num'] is int && w['num'] as int > 0)
            w['num'] as int: (w['output'] ?? '').toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  Future<String?> _swaymsg(List<String> args) async {
    final sock = _sock;
    if (sock == null) return null;
    try {
      final r = await Process.run('swaymsg', args,
          environment: {'SWAYSOCK': sock});
      if (r.exitCode != 0) {
        _log('swaymsg ${args.join(' ')} failed: ${r.stderr}');
        return null;
      }
      return r.stdout as String;
    } catch (e) {
      _log('swaymsg unavailable: $e');
      return null;
    }
  }
}

/// Finds sway's IPC socket without relying on the environment.
///
/// `SWAYSOCK` is exported into sway's own children, and a systemd user
/// service is not one of them unless the session was careful to import it —
/// which is exactly the kind of setup step that makes a helper feel broken.
/// The socket is named predictably in the runtime directory, so look there.
Future<String?> _findSocket() async {
  final env = Platform.environment['SWAYSOCK'] ?? '';
  if (env.isNotEmpty && File(env).existsSync()) return env;

  final dirs = <String>[
    if ((Platform.environment['XDG_RUNTIME_DIR'] ?? '').isNotEmpty)
      Platform.environment['XDG_RUNTIME_DIR']!,
  ];
  if (dirs.isEmpty) {
    // No XDG_RUNTIME_DIR (a bare `su`, a container): fall back to whatever
    // /run/user holds. Sockets there are per-uid and only ours is readable.
    try {
      dirs.addAll(Directory('/run/user')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path));
    } catch (_) {/* nothing to fall back to */}
  }

  final found = <FileSystemEntity>[];
  for (final d in dirs) {
    try {
      found.addAll(Directory(d).listSync().where((e) {
        final name = e.uri.pathSegments.last;
        return name.startsWith('sway-ipc.') && name.endsWith('.sock');
      }));
    } catch (_) {/* unreadable runtime dir */}
  }
  if (found.isEmpty) return null;
  // Newest wins: a crashed session can leave a stale socket behind, and the
  // one belonging to the sway the user is looking at is the recent one.
  found.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  return found.first.path;
}
