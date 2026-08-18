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
import 'package:kanshi_gui/services/workspace_apply_lock.dart';
import 'package:kanshi_gui/services/workspace_daemon_core.dart';

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
    await daemon.core.apply(ApplyReason.startup);
    return;
  }
  // One helper per session. Systemd starts one, but the binary is on PATH
  // and nothing stopped a second from running beside it, each answering the
  // same events with its own idea of the right moment.
  final singleton = WorkspaceApplyLock(WorkspaceApplyLock.singletonLock);
  if (!singleton.tryHold()) {
    stderr.writeln(
        'kanshi-gui-workspaced: another one is already running; stepping aside.');
    return;
  }
  await daemon.run();
}

const _usage = '''
kanshi-gui-workspaced — keeps sway workspaces on the screens kanshi_gui
remembers: at login, whenever you plug a screen in, and after a sway reload.

  --once      apply the current setup's placement and exit
  --dry-run   work out the placement and print it, changing nothing
  -v          log what it decides
  -h          this text

It also puts ONE workspace right when you switch to it and it is on the wrong
screen — a single `move workspace to output`, on the workspace already in
front of you. That is the only time it moves anything you are looking at, and
it is needed because sway keeps the first `workspace N output X` it was given
in a session and ignores every later one.

If you move a workspace to another screen yourself, it stops placing that one
for the rest of the session. Yours wins.

Reads ~/.config/kanshi-gui/settings.json and the kanshi config. Does nothing
at all unless workspace placement is switched on in kanshi_gui.
''';

class _Daemon {
  final bool verbose;

  /// Works everything out and sends nothing. The one honest way to answer
  /// "what would this do to my desk" without doing it.
  final bool dryRun;

  _Daemon({required this.verbose, this.dryRun = false}) {
    core = WorkspaceDaemonCore(
      sway: _SwaymsgConnection(this),
      env: _FileEnvironment(this),
      log: _log,
      dryRun: dryRun,
      withApplyLock: (action) =>
          WorkspaceApplyLock(WorkspaceApplyLock.applyLock).guard(action),
    );
  }

  /// Everything that decides anything lives here, and is driven by a fake
  /// sway in test/workspace_daemon_loop_test.dart. This file is the wiring.
  late final WorkspaceDaemonCore core;

  final _eventStream = StreamController<Map<String, dynamic>>.broadcast();

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

    unawaited(_watchTheFiles());
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
    _configTimer?.cancel();
    _configTimer = null;
    core.replanPending(false);
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

  /// Debounce for a changed settings or kanshi config file. Deliberately not
  /// the settle timer — see [_watchTheFiles].
  Timer? _configTimer;

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
  Future<void> _watchTheFiles() async {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return;
    // The kanshi config can live somewhere else entirely — settings.json may
    // name a path. Watching only the default meant an edit to a custom config
    // was picked up on the next hotplug and not before.
    final custom = (await AppSettings.load()).kanshiConfigPath;
    final dirs = <String>{
      '$home/.config/kanshi-gui',
      '$home/.config/kanshi',
      if (custom != null && custom.isNotEmpty && custom.contains('/'))
        custom.substring(0, custom.lastIndexOf('/')),
    };
    for (final dir in dirs) {
      try {
        final d = Directory(dir);
        if (!d.existsSync()) continue;
        d.watch(events: FileSystemEvent.all).listen((e) {
          final name = e.path.split('/').last;
          final watched = name == 'settings.json' ||
              name == 'config' ||
              (custom != null && e.path == custom);
          if (!watched) return;
          // Its OWN timer. Sharing the settle timer with the hotplug path
          // meant a settings write landing mid-dock cancelled the replan —
          // and the replan is what clears the flag that holds corrections
          // back, so it stayed held for the rest of the session and no
          // workspace was ever put right again.
          _configTimer?.cancel();
          // A file changed, not a screen. Never move anything that is open.
          _configTimer = Timer(
            const Duration(milliseconds: 400),
            () => unawaited(
                core.serialised(() => core.apply(ApplyReason.configChanged))),
          );
        }, onError: (Object _) {/* watch died; events still drive us */});
      } catch (e) {
        _log('cannot watch $dir: $e');
      }
    }
  }

  /// Follows one sway session until its socket closes.
  Future<void> _session() async {
    await core.serialised(() => core.apply(ApplyReason.startup));
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
    _eventStream.add(event);
    final verdict = classifySwayEvent(event);
    switch (verdict.action) {
      case SwayEventAction.none:
        return;
      case SwayEventAction.correct:
        core.noteFocus(verdict.workspace!);
        // Not coalesced and not delayed. The user is looking at this
        // workspace right now; a second and a half later they have already
        // started working on the wrong screen.
        unawaited(core.serialised(
            () => core.correct(verdict.workspace!, verdict.output!)));
        return;
      case SwayEventAction.userMoved:
        // sway emits `move` for our own corrections too; the core tells the
        // two apart because it knows what it just sent.
        core.noteMove(verdict.workspace!, verdict.output!);
        return;
      case SwayEventAction.replan:
        // Docking is a salvo, not an event. Coalesce it, and let kanshi
        // finish switching profiles before asking what the desk looks like.
        //
        // Corrections are held for the whole of that window. Until the new
        // placement is worked out the cached plan still describes the desk
        // that was just unplugged, and a focus event arriving mid-dock would
        // be answered by dragging the workspace back onto a screen the user
        // has just moved away from.
        core.replanPending(true);
        _settleTimer?.cancel();
        _settleTimer = Timer(_settle, () {
          unawaited(core.serialised(() async {
            try {
              await core.apply(ApplyReason.outputsChanged);
            } finally {
              core.replanPending(false);
            }
          }));
        });
        return;
    }
  }

  // ── sway ──────────────────────────────────────────────────────────────

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
/// The real compositor, behind the interface the core is tested against.
class _SwaymsgConnection implements SwayConnection {
  _SwaymsgConnection(this._daemon);
  final _Daemon _daemon;

  @override
  Stream<Map<String, dynamic>> events() => _daemon._eventStream.stream;

  @override
  Future<List<MonitorTileData>> outputs() async {
    final raw = await _daemon._swaymsg(['-t', 'get_outputs']);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final o in list.cast<Map<String, dynamic>>())
          if ((o['name'] ?? '').toString().trim().isNotEmpty) _daemon._output(o),
      ];
    } catch (e) {
      _daemon._log('cannot read outputs: $e');
      return const [];
    }
  }

  @override
  Future<Map<int, String>> workspaceOutputs() async {
    final raw = await _daemon._swaymsg(['-t', 'get_workspaces']);
    if (raw == null) return const {};
    try {
      return {
        for (final w in (jsonDecode(raw) as List).cast<Map<String, dynamic>>())
          if (w['num'] is int && w['num'] as int > 0)
            w['num'] as int: (w['output'] ?? '').toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<int?> focusedWorkspace() async {
    final raw = await _daemon._swaymsg(['-t', 'get_workspaces']);
    if (raw == null) return null;
    try {
      for (final w in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
        if (w['focused'] == true) {
          final n = w['num'];
          return n is int && n > 0 ? n : null;
        }
      }
    } catch (_) {/* malformed reply — do not guess where the user is */}
    return null;
  }

  @override
  Future<bool> run(String command) async =>
      await _daemon._swaymsg([command]) != null;
}

/// The two files on disk, behind the interface the core is tested against.
class _FileEnvironment implements DaemonEnvironment {
  _FileEnvironment(this._daemon);
  final _Daemon _daemon;

  @override
  Future<AppSettings> settings() => AppSettings.load();

  @override
  Future<List<Profile>> profiles() async {
    final s = await AppSettings.load();
    final path = s.kanshiConfigPath?.isNotEmpty == true
        ? s.kanshiConfigPath!
        : '${Platform.environment['HOME']}/.config/kanshi/config';
    try {
      return KanshiConfigParser.parse(await File(path).readAsString());
    } catch (e) {
      _daemon._log('cannot read $path: $e');
      return const [];
    }
  }

  @override
  Future<String?> markedProfile() async {
    try {
      final f = File('${Platform.environment['HOME']}/.current_kanshi_profile');
      if (!await f.exists()) return null;
      final name = (await f.readAsString()).trim();
      return name.isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }
}

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
