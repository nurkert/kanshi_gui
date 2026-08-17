import 'dart:io';

/// Advisory locks shared by the app and the helper.
///
/// Two things can send workspace commands to the same compositor: the app,
/// when the user changes something, and the helper, when a screen appears.
/// Each serialises its OWN work and neither knows about the other, so a
/// hotplug while the app is open has both walking the workspaces at once —
/// two focus walks interleaved, ending wherever the last one happened to
/// land.
///
/// `flock` is the right size of tool here. It costs a file descriptor, it is
/// released by the kernel if a process dies holding it, and it needs no
/// daemon, no socket and no protocol.
class WorkspaceApplyLock {
  /// Where locks live. The runtime directory is per user, cleaned on logout,
  /// and already holds the sway socket both sides talk to.
  static String get _dir =>
      Platform.environment['XDG_RUNTIME_DIR'] ??
      '/tmp/kanshi-gui-${Platform.environment['USER'] ?? 'user'}';

  /// Held for the length of one apply, by whoever is applying.
  static const String applyLock = 'kanshi-gui-workspace-apply.lock';

  /// Held for the lifetime of the helper, so a second one steps aside.
  static const String singletonLock = 'kanshi-gui-workspaced.lock';

  final String name;

  /// Where the lock file lives. Injectable so tests need no control over the
  /// environment.
  final String directory;

  RandomAccessFile? _handle;

  WorkspaceApplyLock(this.name, {String? directory})
      : directory = directory ?? _dir;

  /// Takes the lock, or returns false if someone else holds it.
  ///
  /// Never blocks. A helper that cannot get the singleton lock exits; an
  /// apply that cannot get the apply lock skips, because whoever holds it is
  /// on their way to the same end state anyway.
  bool tryHold() {
    if (_handle != null) return true;
    try {
      final dir = Directory(directory);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('$directory/$name').openSync(mode: FileMode.write);
      try {
        f.lockSync(FileLock.exclusive);
      } on FileSystemException {
        f.closeSync();
        return false;
      }
      _handle = f;
      return true;
    } catch (_) {
      // No runtime directory, a read-only filesystem, a kernel without flock:
      // locking is an optimisation, not a correctness requirement. Behave as
      // if we hold it and carry on.
      return true;
    }
  }

  /// Runs [action] while holding the lock, or skips it if someone else is
  /// already doing the same job.
  Future<bool> guard(Future<void> Function() action) async {
    if (!tryHold()) return false;
    try {
      await action();
      return true;
    } finally {
      release();
    }
  }

  void release() {
    final f = _handle;
    _handle = null;
    if (f == null) return;
    try {
      f.unlockSync();
    } catch (_) {/* already gone */}
    try {
      f.closeSync();
    } catch (_) {/* already gone */}
  }
}
