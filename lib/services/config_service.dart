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

/// Thin filesystem layer around the kanshi config file. Parsing and rendering
/// live in [KanshiConfigParser] / [KanshiConfigWriter] respectively so they
/// can be unit-tested without touching disk.
///
/// The save path is crash-safe and rotates a small number of historical
/// snapshots. On every successful save the previous live config is copied
/// to `<backupPrefix>.<unix-ms>` and the new content is written via
/// `<configPath>.tmp` + atomic `rename`. The backup directory is pruned to
/// the newest [maxBackups] entries.
class ConfigService {
  /// Default location of the kanshi config (`~/.config/kanshi/config`).
  final String configPath;
  /// Backup files use this as their prefix and append `.<unix-ms>`. Older
  /// releases used the prefix verbatim as a single backup file; the
  /// rotation introduced in 1.3.1 keeps the prefix for compat with the
  /// constructor argument while writing timestamped variants.
  final String backupPrefix;
  /// How many timestamped backups to retain. Older ones are pruned after
  /// each successful save.
  final int maxBackups;

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
            "${Platform.environment['HOME']}/.config/kanshi/config.bak",
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

  Future<void> saveProfiles(List<Profile> profiles) async {
    // Refuse to save when the user's main config pulls in other files
    // via `include`. We only parse the main file, so a render-and-
    // overwrite would silently drop the `include` line and orphan
    // every profile defined in the included files. Better to throw
    // here than to corrupt the user's setup.
    if (await hasIncludeDirectives()) {
      throw ConfigHasIncludesException(configPath);
    }
    final rendered =
        KanshiConfigWriter.render(profiles, options: writeOptions);

    final file = File(configPath);
    await Directory(file.parent.path).create(recursive: true);

    File? backup;
    if (await file.exists()) {
      // Snapshot the current live config to a fresh timestamped backup
      // *before* attempting the new write, so we can roll back if the
      // tmp+rename below fails for any reason.
      final ts = DateTime.now().millisecondsSinceEpoch;
      backup = await file.copy('$backupPrefix.$ts');
    }

    final tmp = File('$configPath.tmp');
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
}
