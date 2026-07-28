import 'dart:async';
import 'dart:io';

import 'package:kanshi_gui/models/profiles.dart';
import 'package:kanshi_gui/services/kanshi_config_parser.dart';
import 'package:kanshi_gui/services/kanshi_config_writer.dart';

/// Thrown by [ConfigService.saveProfiles] when the live kanshi config
/// uses `include` directives. Saving would render only the profiles
/// the GUI parsed (the main file's profiles, NOT the included
/// files') and would silently drop the `include` line, orphaning
/// every profile in the included files. Refuse rather than corrupt.
class ConfigHasIncludesException implements Exception {
  final String configPath;
  const ConfigHasIncludesException(this.configPath);
  @override
  String toString() =>
      'kanshi config at $configPath uses `include` directives. '
      'Saving would overwrite them and orphan profiles in the '
      'included files. Move profiles into the main config to '
      're-enable saving from the GUI.';
}

/// Thrown by [ConfigService.saveProfiles] when the live kanshi config holds
/// constructs the parser did not understand.
///
/// The GUI re-renders the entire config from its in-memory model, so saving a
/// file it only partially read deletes whatever it never saw. A hand-written
/// config using kanshi's optional-`enable` form used to parse as zero
/// monitors per profile; the writer skips empty profiles; the first save
/// therefore replaced the user's file with an empty one.
class ConfigNotFullyParsedException implements Exception {
  final String configPath;

  /// What would be lost, e.g. "2 of 3 output lines".
  final String loss;

  const ConfigNotFullyParsedException(this.configPath, this.loss);

  @override
  String toString() =>
      'kanshi config at $configPath uses syntax kanshi_gui does not model yet '
      '($loss would be dropped). Refusing to save rather than delete it.';
}

/// Thrown when the freshly rendered config does not read back as the model
/// that produced it. A writer bug must not reach the user's disk.
class ConfigRoundTripException implements Exception {
  final String detail;
  const ConfigRoundTripException(this.detail);
  @override
  String toString() =>
      'refusing to save: the rendered config does not read back as written '
      '($detail). This is a bug in kanshi_gui, not in your config.';
}

/// Thin filesystem layer around the kanshi config file. Parsing and rendering
/// live in [KanshiConfigParser] / [KanshiConfigWriter] respectively so they
/// can be unit-tested without touching disk.
///
/// The save path is crash-safe and rotates a small number of historical
/// snapshots. On every successful save the previous live config is copied
/// to `<backupPrefix>.<unix-ms>` and the new content is written via
/// `<configPath>.tmp` + atomic `rename`. The backup directory is pruned to
/// the newest [maxBackups] entries.
///
/// Saves are also content-deduplicated: when the rendered profiles produce
/// byte-identical output to the live config, [saveProfiles] returns
/// without writing or creating a backup. This prevents drag-then-cancel
/// cycles, undo/redo round-trips, and profile-switch-and-back from
/// littering the backup directory with identical snapshots — a long-
/// standing complaint that turned `~/.config/kanshi/` into a wall of
/// near-duplicate files.
class ConfigService {
  /// Default location of the kanshi config (`~/.config/kanshi/config`).
  final String configPath;
  /// Backup files use this as their prefix and append `.<unix-ms>`. Older
  /// releases used the prefix verbatim as a single backup file; the
  /// rotation introduced in 1.3.1 keeps the prefix for compat with the
  /// constructor argument while writing timestamped variants. 1.5.7
  /// relocates the default into a `backups/` sub-directory so the main
  /// config dir stays tidy.
  final String backupPrefix;
  /// How many timestamped backups to retain. Older ones are pruned after
  /// each successful save. Mutable so the settings UI can retune it.
  int maxBackups;

  /// Write options used when serialising profiles. Defaults to a
  /// compositor-neutral profile (no Sway-specific exec lines). The Sway
  /// backend (or callers that know they target Sway) override this.
  KanshiWriteOptions writeOptions;

  ConfigService({
    String? configPath,
    String? backupPrefix,
    KanshiWriteOptions? writeOptions,
    this.maxBackups = 10,
  })  : configPath = configPath ??
            "${Platform.environment['HOME']}/.config/kanshi/config",
        backupPrefix = backupPrefix ??
            "${Platform.environment['HOME']}/.config/kanshi/backups/config.bak",
        writeOptions = writeOptions ?? KanshiWriteOptions.swayDefaults;

  Future<List<Profile>> loadProfiles() async {
    final file = File(configPath);
    if (!await file.exists()) return [];
    final content = await file.readAsString();
    return KanshiConfigParser.parse(content);
  }

  /// True iff the live kanshi config contains an `include <pattern>`
  /// directive (kanshi's DSL feature for splitting profiles across
  /// files). Result is cached after the first call to keep the save
  /// hot-path fast — the file's include-status is treated as stable
  /// for the lifetime of the controller; a user who edits in their
  /// includes mid-session needs to relaunch the GUI.
  ///
  /// `#`-commented include lines do not count; the line is stripped
  /// of trailing comments via the same simple split as
  /// `KanshiConfigParser._stripComments`.
  bool? _hasIncludesCache;
  Future<bool> hasIncludeDirectives() async {
    final cached = _hasIncludesCache;
    if (cached != null) return cached;
    final file = File(configPath);
    if (!await file.exists()) {
      _hasIncludesCache = false;
      return false;
    }
    final content = await file.readAsString();
    final result = content.split('\n').any((line) {
      // Strip inline comments. We don't care about quoting here —
      // kanshi profile names with literal `#` are not a real
      // collision risk because the include directive lives outside
      // any profile block.
      final hashIdx = line.indexOf('#');
      final stripped = (hashIdx == -1 ? line : line.substring(0, hashIdx))
          .trim();
      // `include <pattern>` — pattern must be non-empty.
      return RegExp(r'^include\s+\S').hasMatch(stripped);
    });
    _hasIncludesCache = result;
    return result;
  }

  /// Describes what the parser could not read out of the live config, or null
  /// when it understood all of it (including when there is no file yet).
  ///
  /// Cached like [hasIncludeDirectives], and for the same reason: it is
  /// consulted on the save hot path and the file's shape is treated as stable
  /// for the lifetime of the controller. [invalidateInspectionCache] clears
  /// it after the GUI itself rewrites the file.
  String? _unparsedCache;
  bool _unparsedCacheValid = false;
  Future<String?> unparsedContentDescription() async {
    if (_unparsedCacheValid) return _unparsedCache;
    final file = File(configPath);
    if (!await file.exists()) {
      _unparsedCache = null;
      _unparsedCacheValid = true;
      return null;
    }
    final content = await file.readAsString();
    _unparsedCache = KanshiConfigParser.diagnose(content).lossDescription;
    _unparsedCacheValid = true;
    return _unparsedCache;
  }

  /// Drops the cached inspection results. Called after the GUI writes the
  /// file, since it just replaced the content the cache described.
  void invalidateInspectionCache() {
    _unparsedCacheValid = false;
    _unparsedCache = null;
    _hasIncludesCache = null;
  }

  /// Verifies that [rendered] reads back as [profiles].
  static void _assertRoundTrips(List<Profile> profiles, String rendered) {
    // Empty profiles are intentionally not rendered, so they are excluded
    // from the comparison rather than counted as a loss.
    final expected = profiles.where((p) => p.monitors.isNotEmpty).toList();
    final actual = KanshiConfigParser.parse(rendered);

    if (actual.length != expected.length) {
      throw ConfigRoundTripException(
          'wrote ${expected.length} profiles, read back ${actual.length}');
    }
    for (var i = 0; i < expected.length; i++) {
      if (actual[i].name != expected[i].name) {
        throw ConfigRoundTripException(
            'profile ${i + 1} came back as "${actual[i].name}" instead of '
            '"${expected[i].name}"');
      }
      if (actual[i].monitors.length != expected[i].monitors.length) {
        throw ConfigRoundTripException(
            'profile "${expected[i].name}" wrote '
            '${expected[i].monitors.length} outputs, read back '
            '${actual[i].monitors.length}');
      }
    }
  }

  /// Serialises writes so two saves can never interleave.
  ///
  /// [saveProfiles] is async and was previously re-entrant: two overlapping
  /// calls both took a backup, both wrote the SAME `<path>.tmp`, and both
  /// renamed it over the live config. The loser's rename hit a file the
  /// winner had already moved, and the file could end up holding the older
  /// of the two renders — i.e. an edit silently rolled back.
  Future<void> _writeChain = Future.value();

  /// Distinguishes temp files between processes and instances.
  static int _writeSeq = 0;

  Future<void> saveProfiles(List<Profile> profiles) {
    // A snapshot per call: `profiles` and its Profile objects are mutable and
    // owned by the controller, which keeps editing while a write is queued.
    // Without this, a queued save would render whatever the model looks like
    // when it finally runs, not what the caller asked to persist.
    final snapshot = [
      for (final p in profiles)
        Profile(name: p.name, monitors: List.of(p.monitors)),
    ];
    final completer = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        await _saveProfilesLocked(snapshot);
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _saveProfilesLocked(List<Profile> profiles) async {
    // Refuse to save when the user's main config pulls in other files
    // via `include`. We only parse the main file, so a render-and-
    // overwrite would silently drop the `include` line and orphan
    // every profile defined in the included files. Better to throw
    // here than to corrupt the user's setup.
    if (await hasIncludeDirectives()) {
      throw ConfigHasIncludesException(configPath);
    }

    // Gate 1 — do not overwrite a file we only partially understood.
    // Anything the parser could not read is not in the model, so rendering
    // the model back would delete it.
    final loss = await unparsedContentDescription();
    if (loss != null) {
      throw ConfigNotFullyParsedException(configPath, loss);
    }

    final rendered =
        KanshiConfigWriter.render(profiles, options: writeOptions);

    // Gate 2 — the rendered text must read back as the model that produced
    // it. This catches writer bugs before they reach the user's disk rather
    // than after, which is how the transposed-mode oscillation survived so
    // long.
    _assertRoundTrips(profiles, rendered);

    final file = File(configPath);
    await Directory(file.parent.path).create(recursive: true);

    // One-time relocation of any legacy `<configDir>/config.bak[.<ts>]`
    // files into the new `<configDir>/backups/` layout. Lazy + idempotent.
    await _migrateLegacyBackupsIfNeeded();

    // Skip-if-identical: when the rendered output is byte-for-byte the
    // same as the live config, suppress the save entirely. Without
    // this, drag-then-drop-back / undo-redo round-trips / profile-
    // switch-and-back each produce an identical backup snapshot,
    // burning through the rotation ring within minutes.
    if (await file.exists()) {
      try {
        final current = await file.readAsString();
        if (current == rendered) return;
      } catch (_) {
        // Read failed (permissions, disk error, …) — fall through and
        // let the write attempt either succeed or surface the real
        // error from there.
      }
    }

    await Directory(File(backupPrefix).parent.path).create(recursive: true);

    File? backup;
    if (await file.exists()) {
      // Snapshot the current live config to a fresh timestamped backup
      // *before* attempting the new write, so we can roll back if the
      // tmp+rename below fails for any reason.
      final ts = DateTime.now().millisecondsSinceEpoch;
      backup = await file.copy('$backupPrefix.$ts');
    }

    final tmp = File('$configPath.tmp.${pid}_${_writeSeq++}');
    try {
      // Atomic write: a partial failure leaves the live config untouched
      // (the tmp file is on the same filesystem so rename is atomic).
      await tmp.writeAsString(rendered, flush: true);
      await tmp.rename(configPath);
    } catch (e) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {/* best effort cleanup */}
      }
      if (backup != null && await backup.exists()) {
        // Best-effort restore: if the live config was clobbered before
        // the rename failed (it shouldn't have been, but defend anyway),
        // copy the backup back.
        try {
          await backup.copy(configPath);
        } catch (_) {/* best effort */}
      }
      rethrow;
    }

    // The file the inspection cache described has just been replaced by our
    // own output, which is lossless by construction (gate 2 above).
    _unparsedCache = null;
    _unparsedCacheValid = true;

    // Pruning happens after a successful write so a failed save never
    // walks the backup ring forward.
    await _pruneBackups();
  }

  /// Returns the timestamped backup files, newest first.
  Future<List<File>> listBackups() async {
    final prefixFile = File(backupPrefix);
    final dir = Directory(prefixFile.parent.path);
    if (!await dir.exists()) return [];
    final base = prefixFile.uri.pathSegments.last;
    final entries = <File>[];
    await for (final ent in dir.list(followLinks: false)) {
      if (ent is! File) continue;
      final name = ent.uri.pathSegments.last;
      if (!name.startsWith('$base.')) continue;
      // Reject anything that doesn't have a numeric timestamp suffix —
      // we share the directory with the live config and any stray files.
      final suffix = name.substring(base.length + 1);
      if (int.tryParse(suffix) == null) continue;
      entries.add(ent);
    }
    entries.sort((a, b) {
      int ts(String p) => int.parse(p.substring(p.lastIndexOf('.') + 1));
      return ts(b.path).compareTo(ts(a.path));
    });
    return entries;
  }

  /// Newest timestamped backup, or null if no rotated backup exists.
  Future<File?> newestBackup() async {
    final list = await listBackups();
    return list.isEmpty ? null : list.first;
  }

  Future<void> _pruneBackups() async {
    final list = await listBackups();
    if (list.length <= maxBackups) return;
    for (final f in list.skip(maxBackups)) {
      try {
        await f.delete();
      } catch (_) {/* best effort */}
    }
  }

  /// Set once we've checked / completed the one-time relocation of
  /// legacy backups for the lifetime of this [ConfigService] instance.
  /// Subsequent saves skip the scan; instance-scoped is fine because
  /// after the first migration the source directory has no matching
  /// files left to move anyway.
  bool _legacyMigrationDone = false;

  /// Move any `config.bak[.<ts>]` files that pre-1.5.7 releases dropped
  /// next to the live config into the new `<backupDir>/` layout, and
  /// delete the pre-1.3.1 single-file `config.bak` (no suffix) since
  /// the rotation logic has never been able to clean it up. Skipped
  /// when backup and config directories coincide (test fixtures and
  /// users who explicitly opt into the old layout).
  Future<void> _migrateLegacyBackupsIfNeeded() async {
    if (_legacyMigrationDone) return;
    _legacyMigrationDone = true;

    final configDir = File(configPath).parent.path;
    final backupFile = File(backupPrefix);
    final backupDir = backupFile.parent.path;
    if (configDir == backupDir) return;

    final liveDir = Directory(configDir);
    if (!await liveDir.exists()) return;
    final base = backupFile.uri.pathSegments.last; // e.g. "config.bak"

    final toMigrate = <File>[];
    final toDelete = <File>[];
    await for (final ent in liveDir.list(followLinks: false)) {
      if (ent is! File) continue;
      final name = ent.uri.pathSegments.last;
      if (name == base) {
        // Pre-rotation single-file backup — orphan since 1.3.1.
        toDelete.add(ent);
        continue;
      }
      if (!name.startsWith('$base.')) continue;
      final suffix = name.substring(base.length + 1);
      // Only relocate the canonical timestamped form. Anything else
      // (e.g. `config.bak.notes`) is the user's — leave it alone.
      if (int.tryParse(suffix) == null) continue;
      toMigrate.add(ent);
    }

    if (toMigrate.isNotEmpty) {
      await Directory(backupDir).create(recursive: true);
    }
    for (final src in toMigrate) {
      final name = src.uri.pathSegments.last;
      final dest = '$backupDir/$name';
      try {
        await src.rename(dest);
      } catch (_) {
        // Cross-filesystem rename fails with EXDEV — copy then delete.
        try {
          await src.copy(dest);
          await src.delete();
        } catch (_) {/* best effort */}
      }
    }
    for (final f in toDelete) {
      try {
        await f.delete();
      } catch (_) {/* best effort */}
    }
  }
}
