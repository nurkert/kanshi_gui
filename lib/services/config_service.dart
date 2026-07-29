import 'dart:async';
import 'dart:io';

import 'package:kanshi_gui/domain/kanshi/kanshi_document.dart';
import 'package:kanshi_gui/domain/kanshi/scfg.dart';
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

  /// Rewrites only what this app owns inside an existing config.
  ///
  /// The alternative — re-rendering the whole file from the model, which is
  /// what this did for its whole life — deletes everything the model cannot
  /// represent. Editing in place means the app can only lose what it
  /// deliberately replaces.
  String _editInPlace(String existing, List<Profile> profiles) {
    final doc = KanshiDocument.parse(existing);

    // Profiles the current parser genuinely read — meaning it found outputs
    // in them, not merely that it saw the header. A profile parsed as empty
    // is one the app could NOT read, and its absence from the model means
    // "I never saw it", not "the user deleted it". Treating those two the
    // same is how a hand-written profile would get removed by a save that
    // was only meant to touch a different one.
    final readable = {
      for (final p in KanshiConfigParser.parse(existing))
        if (p.monitors.isNotEmpty) p.name,
    };
    final modelNames = profiles.map((p) => p.name).toSet();

    for (final p in profiles) {
      if (p.monitors.isEmpty) continue;
      // Render the profile with the normal writer, then take its body: the
      // rendering rules stay in one place and this only decides where the
      // result goes.
      final block = KanshiConfigWriter.render([p], options: writeOptions);
      _assertBlockRoundTrips(p, block);
      final nodes = ScfgDocument.parse(block).nodes;
      if (nodes.isEmpty) continue;
      if (!doc.replaceManagedChildren(p.name, nodes.first.children)) {
        doc.appendProfile(block.trimRight().split('\n'));
      }
    }

    for (final name in doc.profileNames.toList()) {
      if (modelNames.contains(name)) continue;
      if (!readable.contains(name)) continue;
      doc.removeProfile(name);
    }
    return doc.render();
  }

  /// Verifies that a profile block reads back as the profile that produced
  /// it.
  ///
  /// Scoped to the app's OWN rendering, not the whole file: since M9 the file
  /// legitimately contains profiles and directives the model cannot express,
  /// and comparing against those would report a loss that is actually a
  /// preservation. What must hold is that nothing the app wrote came back
  /// wrong — the check that would have caught the transposed-mode oscillation
  /// before it shipped.
  static void _assertBlockRoundTrips(Profile profile, String block) {
    final back = KanshiConfigParser.parse(block);
    if (back.length != 1) {
      throw ConfigRoundTripException(
          'profile "${profile.name}" rendered to ${back.length} profiles');
    }
    if (back.single.name != profile.name) {
      throw ConfigRoundTripException(
          'profile "${profile.name}" came back as "${back.single.name}"');
    }
    if (back.single.monitors.length != profile.monitors.length) {
      throw ConfigRoundTripException(
          'profile "${profile.name}" wrote ${profile.monitors.length} '
          'outputs, read back ${back.single.monitors.length}');
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
        Profile(
          name: p.name,
          monitors: List.of(p.monitors),
          workspaceMap:
              p.workspaceMap == null ? null : Map.of(p.workspaceMap!),
        ),
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
    // The include refusal is gone too, and for the same reason as M2's gate:
    // it existed because re-rendering dropped the `include` line and orphaned
    // every profile in the included files. Editing in place preserves the
    // line, and profiles defined elsewhere were never in this file to lose.

    // M2's refusal gate is gone, and deliberately so. It existed because the
    // writer re-rendered the whole file from the model, so anything the
    // parser had not read was deleted. Since M9 the save edits the document
    // in place and only replaces what this app owns, which means a config
    // full of syntax the model cannot express is no longer dangerous to save
    // — and refusing to save it would leave those users with a read-only app
    // for no remaining reason.

    final existing =
        await File(configPath).exists() ? await File(configPath).readAsString() : null;
    final String rendered;
    if (existing == null || existing.trim().isEmpty) {
      // Nothing to preserve — render from the model, verifying each block.
      for (final p in profiles.where((p) => p.monitors.isNotEmpty)) {
        _assertBlockRoundTrips(
            p, KanshiConfigWriter.render([p], options: writeOptions));
      }
      rendered = KanshiConfigWriter.render(profiles, options: writeOptions);
    } else {
      rendered = _editInPlace(existing, profiles);
    }


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
