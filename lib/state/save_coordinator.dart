import 'dart:async';

import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/config_service.dart';

/// Why a save was refused, in the words the user reads.
class SaveBlockedReasons {
  SaveBlockedReasons._();

  static const String includes =
      'Your kanshi config uses `include` directives. kanshi_gui will not save '
      'to avoid orphaning profiles in the included files. Move those profiles '
      'into the main config to re-enable saving.';

  static String notFullyParsed(String loss) =>
      'Your kanshi config uses syntax kanshi_gui does not understand yet, and '
      '$loss would be deleted if it saved. Your changes are being kept in '
      'memory only.';

  static String writeFailed(Object e) =>
      'Could not write your kanshi config: $e. Your changes are being kept '
      'in memory only and will be lost when you close the app.';
}

/// Owns everything about getting profiles onto disk: the debounce, the
/// knowledge of whether saving is allowed at all, and what happened last
/// time.
///
/// Pulled out of the controller because these were four unrelated-looking
/// fields (`_saveTimer`, `_configHasIncludes`, `_configUnparsedLoss`,
/// `_lastSaveOk`) that only make sense together, and because the same
/// five-branch error routing was written out twice — once for the debounced
/// path and once for the flush path, with the two drifting apart. Every
/// failure now goes through one place, which is what stops a write error
/// being reported as success.
class SaveCoordinator {
  final ConfigService config;

  /// How long edits are collected before a write. A drag produces a burst of
  /// mutations and each one calls [schedule].
  Duration debounce;

  SaveCoordinator(
    this.config, {
    this.debounce = const Duration(milliseconds: 600),
  });

  Timer? _timer;

  /// Whether the last attempted write reached disk. Null before the first
  /// attempt of the session.
  bool? lastSaveOk;

  /// Set when the parser could not read all of the live config, describing
  /// what would be lost. While non-null, saving is refused rather than
  /// deleting what was never read.
  String? unparsedLoss;

  /// Called with a human-readable reason whenever a save is refused or fails.
  /// A silent refusal would be worse than the data loss it prevents.
  void Function(String reason)? onBlocked;

  /// Called after any state change worth a repaint.
  void Function()? onChanged;

  /// Why saving is currently refused, or null when it is not.
  ///
  /// Since M9 the save edits the document in place, so neither an `include`
  /// directive nor syntax the model cannot express is a reason to refuse —
  /// nothing is re-rendered over them. Only a genuine write failure blocks.
  String? get blockedReason => null;

  /// Re-reads the shape of the live config. Called at startup and after the
  /// file is replaced from outside our own writes.
  Future<void> inspect() async {
    try {
      unparsedLoss = await config.unparsedContentDescription();
    } catch (_) {
      unparsedLoss = null;
    }
  }

  /// Queues a debounced write of [profiles].
  void schedule(List<Profile> profiles) {
    _timer?.cancel();
    _timer = Timer(debounce, () {
      // Fire-and-forget by design: the next mutation re-triggers. Errors are
      // NOT dropped, though — that is the whole point of _route.
      // ignore: discarded_futures
      config.saveProfiles(profiles).then((_) {
        lastSaveOk = true;
        onChanged?.call();
      }).catchError((Object e) {
        _route(e);
      });
    });
  }

  /// Writes [profiles] now, waiting for the result. Returns true on success.
  Future<bool> flush(List<Profile> profiles) async {
    _timer?.cancel();
    try {
      await config.saveProfiles(profiles);
      lastSaveOk = true;
      return true;
    } catch (e) {
      _route(e);
      return false;
    }
  }

  /// Cancels a pending debounced write without performing it.
  void cancel() => _timer?.cancel();

  void dispose() => _timer?.cancel();

  void _route(Object e) {
    lastSaveOk = false;
    if (e is ConfigNotFullyParsedException) {
      unparsedLoss = e.loss;
      onBlocked?.call(SaveBlockedReasons.notFullyParsed(e.loss));
    } else if (e is ConfigRoundTripException) {
      onBlocked?.call(e.toString());
    } else {
      // Read-only config, a full disk, a vanished directory. This used to be
      // swallowed as "best effort", so undo/redo/setMirror reported success
      // while nothing had been written.
      onBlocked?.call(SaveBlockedReasons.writeFailed(e));
    }
    onChanged?.call();
  }
}
