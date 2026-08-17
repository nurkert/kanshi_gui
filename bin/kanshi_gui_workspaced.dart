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
// that: it re-applies at login and on every hotplug, and re-declares after a
// `swaymsg reload` wipes the workspace configs.
//
// It deliberately does NOT react to individual workspaces opening. It did, and
// that fed itself: relocating a workspace means focusing it, focusing away
// leaves it empty, sway garbage-collects an empty workspace, and the next
// command recreates it — 975 workspace events in three seconds on a real desk.
// A helper must not answer events its own commands produce.
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

/// How long a single `swaymsg` may take before it is killed. Matches the
/// app's own [ProcessRunner.defaultTimeout] for the same commands.
const _swaymsgDeadline = Duration(seconds: 5);

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

  void _log(String message) {
    if (verbose) stdout.writeln('kanshi-gui-workspaced: $message');
  }

  Future<void> attach(String sock) async => _sock = sock;

  Future<void> run() async {
    // A clean exit matters more here than in a short-lived process: the
    // subscribe subprocess is a CHILD, and Dart does not take children down
    // with it. Under systemd the cgroup kill covers that, but a helper anyone
    // can also run by hand must not leave a swaymsg behind every time it is
    // stopped with ^C.
    for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
      signal.watch().listen((_) {
        _stopping = true;
        _closeSession();
        exit(0);
      });
    }

    _watchTheFiles();
    _watchMyself();

    // One process, many sway sessions: a user who logs out and back in keeps
    // the same systemd user manager, so the loop outlives any single socket.
    while (!_stopping) {
      final started = DateTime.now();
      if (_ownBinaryChanged()) {
        // dpkg replaced the file under a running process, or removed it. A
        // process keeps its own executable image alive through both, so
        // without this the machine goes on running the version that was
        // uninstalled half an hour ago — still moving workspaces after
        // `apt remove`, and still carrying the bug an upgrade just fixed.
        // Exiting hands the decision back to systemd: `Restart=always`
        // brings up the new binary, and after a removal there is nothing to
        // bring up and the unit stays down.
        _log('the binary under me changed; exiting so systemd can restart');
        _closeSession();
        exit(0);
      }
      final sock = await _findSocket();
      if (sock != null) {
        _sock = sock;
        _log('attached to $sock');
        await _session();
        _log('sway went away');
        _settleTimer?.cancel();
      }
      // The floor is the whole point, and it is outside the `sock == null`
      // branch on purpose. A sway that died without cleaning up leaves its
      // socket file on disk: _findSocket keeps returning that path, every
      // connection to it fails instantly, _session returns in microseconds,
      // and the loop spins a core flat for as long as the stale file exists.
      // Sleeping the remainder of the poll interval costs nothing when a
      // session really did run for hours.
      final elapsed = DateTime.now().difference(started);
      if (elapsed < _swayPoll) {
        await Future<void>.delayed(_swayPoll - elapsed);
      }
    }
  }

  /// True once a termination signal has been seen, so the loop stops instead
  /// of racing the exit.
  bool _stopping = false;

  /// Identity of this executable when the daemon started, for
  /// [_ownBinaryChanged]. Null when it cannot be read, which disables the
  /// check rather than making it fire constantly.
  final FileStat? _ownBinary = _statSelf();

  static FileStat? _statSelf() {
    try {
      final f = File(Platform.resolvedExecutable);
      return f.existsSync() ? f.statSync() : null;
    } catch (_) {
      return null;
    }
  }

  bool _ownBinaryChanged() {
    final was = _ownBinary;
    if (was == null) return false;
    final now = _statSelf();
    if (now == null) return true; // removed
    return now.modified != was.modified || now.size != was.size;
  }

  /// The subscribe subprocess of the session in progress.
  Process? _subscriber;

  void _closeSession() {
    _selfCheck?.cancel();
    _selfCheck = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _subscriber?.kill(ProcessSignal.sigterm);
    _subscriber = null;
  }

  /// Notices an upgrade or a removal, on a timer of its own.
  ///
  /// This check used to live at the top of the main loop, which sounds right
  /// and never ran: the loop body blocks inside [_session] for the entire
  /// length of a sway session, so the top of the loop is reached roughly once
  /// per login. Installing 2.1.1 over 2.1.0 left the previous binary running
  /// with the previous bugs, and the only thing that revealed it was looking
  /// at the pid afterwards.
  ///
  /// A minute is plenty: nothing goes wrong while the old process is still
  /// running, it just is not the version the user installed.
  void _watchMyself() {
    _selfCheck = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!_ownBinaryChanged()) return;
      _log('the binary under me changed; exiting so systemd can restart');
      _closeSession();
      exit(0);
    });
  }

  Timer? _selfCheck;

  /// Re-plans when the app changes its mind.
  ///
  /// Everything is re-read on each apply, but an apply only happens on a sway
  /// event — so choosing a different pattern in the GUI took effect for the
  /// running session (the app applies it directly) and then sat unnoticed
  /// here until the next hotplug. A workspace opened in between went to the
  /// old place. Watching the two files closes that gap, and costs one inotify
  /// watch.
  ///
  /// The DIRECTORY, not the file: both are written by writing a temp file and
  /// renaming it over the target, which replaces the inode and would leave a
  /// watch on the old one pointing at nothing.
  void _watchTheFiles() {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return;
    for (final dir in ['$home/.config/kanshi-gui', '$home/.config/kanshi']) {
      try {
        final d = Directory(dir);
        if (!d.existsSync()) continue;
        d.watch(events: FileSystemEvent.all).listen((e) {
          final name = e.path.split('/').last;
          if (name != 'settings.json' && name != 'config') return;
          _settleTimer?.cancel();
          _settleTimer = Timer(
            const Duration(milliseconds: 400),
            () => unawaited(_serialised(() => apply(force: true))),
          );
        }, onError: (Object _) {/* watch died; events still drive us */});
      } catch (e) {
        _log('cannot watch $dir: $e');
      }
    }
  }

  /// Follows one sway session until its socket closes.
  Future<void> _session() async {
    await _serialised(() => apply(force: true));
    final Process proc;
    try {
      proc = await Process.start(
        'swaymsg',
        ['-t', 'subscribe', '-m', '["output","workspace"]'],
        environment: {'SWAYSOCK': _sock!},
      );
    } catch (e) {
      // swaymsg missing while a socket exists. Uncaught, this threw out of
      // run() and killed the process — which systemd then restarted, which
      // threw again: a crash loop that fills the journal and never explains
      // itself. There is nothing to do but wait; the caller's poll interval
      // handles the pacing.
      _log('cannot subscribe to sway events: $e');
      return;
    }
    _subscriber = proc;
    try {
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
    } finally {
      // The stream can end without the process having exited — an error on
      // stdout, a decode failure. Going round the loop then would start a
      // second subscriber and abandon this one, once per iteration, forever.
      proc.kill(ProcessSignal.sigterm);
      if (identical(_subscriber, proc)) _subscriber = null;
    }
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
        _settleTimer = Timer(
          _settle,
          () => unawaited(_serialised(() => apply(force: true))),
        );
        return;
    }
  }

  /// Runs [action] after everything already queued.
  ///
  /// Both things this daemon does end in a `swaymsg` call, and both are
  /// reached from event handlers that do not wait for each other: a settle
  /// timer firing a full re-apply while a workspace-init is mid-flight would
  /// interleave two command streams into one compositor. Worse, the re-apply
  /// reads the live workspace layout to decide whether the visible repair is
  /// needed — reading it halfway through someone else's moves gives an answer
  /// that was never true.
  ///
  /// A one-deep chain rather than a lock: the work is short, ordering is what
  /// matters, and a failed step must not wedge the ones behind it.
  Future<void> _serialised(Future<void> Function() action) {
    final next = _queue.then((_) async {
      try {
        await action();
      } catch (e) {
        _log('step failed: $e');
      }
    });
    _queue = next;
    return next;
  }

  Future<void> _queue = Future<void>.value();

  /// Recomputes the placement from the files and the live outputs, and hands
  /// it to sway.
  ///
  /// Everything is re-read every time. The settings and the config are small,
  /// this runs on a hotplug rather than on a frame, and re-reading is what
  /// makes the switch in the GUI take effect without restarting the service.
  /// When each of the recent applies happened, for [_runawayGuard].
  final List<DateTime> _recentApplies = [];

  /// Refuses to keep going when the applies come too fast.
  ///
  /// A helper that talks to the compositor in response to compositor events
  /// can, if any future change gets that wiring wrong, feed itself. It did:
  /// 975 workspace events in three seconds, a third of a core, and a desktop
  /// nobody could use. The wiring that caused it is gone, but the property
  /// worth having is that no wiring mistake can ever do that again — so the
  /// helper stops itself instead of the user having to.
  ///
  /// Twelve a minute is far above any real desk: docking produces one, a
  /// reload one, a settings change one.
  bool _runawayGuard() {
    final now = DateTime.now();
    _recentApplies.removeWhere(
        (t) => now.difference(t) > const Duration(minutes: 1));
    if (_recentApplies.length >= 12) {
      _log('too many applies in a minute — standing down until it settles');
      return true;
    }
    _recentApplies.add(now);
    return false;
  }

  Future<void> apply({bool force = false}) async {
    if (_runawayGuard()) return;
    final settings = await AppSettings.load();
    final mode = settings.workspaceManagement;
    if (!mode.enabled) {
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
      _log('no remembered setup matches these screens');
      return;
    }

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

  /// One short-lived `swaymsg`, with a deadline.
  ///
  /// The deadline is not decoration. A compositor that stops answering leaves
  /// the call pending forever; every hotplug and every workspace opened after
  /// that queues another one behind it, and the daemon becomes a pile of
  /// stuck subprocesses that never reports anything wrong. Five seconds is
  /// what the app's own [ProcessRunner] allows these same commands.
  Future<String?> _swaymsg(List<String> args) async {
    final sock = _sock;
    if (sock == null) return null;
    Process? proc;
    try {
      proc = await Process.start('swaymsg', args,
          environment: {'SWAYSOCK': sock});
      final out = proc.stdout.transform(utf8.decoder).join();
      final err = proc.stderr.transform(utf8.decoder).join();
      final code = await proc.exitCode.timeout(_swaymsgDeadline);
      if (code != 0) {
        _log('swaymsg ${args.join(' ')} failed: ${await err}');
        return null;
      }
      return await out;
    } on TimeoutException {
      _log('swaymsg ${args.join(' ')} did not answer in $_swaymsgDeadline');
      proc?.kill(ProcessSignal.sigkill);
      return null;
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
