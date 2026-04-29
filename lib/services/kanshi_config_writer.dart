import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/models/profiles.dart';

/// Knobs that influence what the [KanshiConfigWriter] emits in addition to
/// the bare per-output lines. These reflect the historically Sway-specific
/// behaviours of the app — they default to *off* so the writer is
/// compositor-neutral by default and only enables the Sway extras when the
/// caller (typically the SwayBackend) explicitly asks for them.
class KanshiWriteOptions {
  final bool injectSwayWorkspaceExec;
  final bool writeCurrentProfileMarker;

  const KanshiWriteOptions({
    this.injectSwayWorkspaceExec = false,
    this.writeCurrentProfileMarker = false,
  });

  static const swayDefaults = KanshiWriteOptions(
    injectSwayWorkspaceExec: true,
    writeCurrentProfileMarker: true,
  );

  static const neutral = KanshiWriteOptions();
}

class KanshiConfigWriter {
  KanshiConfigWriter._();

  static String render(
    List<Profile> profiles, {
    KanshiWriteOptions options = KanshiWriteOptions.neutral,
  }) {
    final buffer = StringBuffer();
    for (final profile in profiles) {
      if (profile.monitors.isEmpty) continue;
      _renderProfile(buffer, profile, options);
    }
    return buffer.toString();
  }

  static void _renderProfile(
    StringBuffer buffer,
    Profile profile,
    KanshiWriteOptions options,
  ) {
    final referenceMonitors =
        profile.monitors.where((m) => m.enabled).toList();
    final baseForOffsets =
        referenceMonitors.isNotEmpty ? referenceMonitors : profile.monitors;

    final minX =
        baseForOffsets.map((m) => m.x).reduce((a, b) => a < b ? a : b);
    final minY =
        baseForOffsets.map((m) => m.y).reduce((a, b) => a < b ? a : b);
    final offsetX = (minX < 0) ? -minX : 0.0;
    final offsetY = (minY < 0) ? -minY : 0.0;

    final mons = profile.monitors
        .map((m) => _sanitizeMonitor(m, offsetX, offsetY))
        .toList()
      ..sort((a, b) {
        final byX = a.x.compareTo(b.x);
        if (byX != 0) return byX;
        return a.id.compareTo(b.id);
      });

    buffer.writeln("profile '${profile.name}' {");

    for (final m in mons) {
      if (!m.enabled) {
        buffer.writeln("    output '${m.id}' disable");
        continue;
      }
      // mode line is always landscape-oriented, transform handles rotation.
      final baseW = (m.rotation % 180 == 0) ? m.width : m.height;
      final baseH = (m.rotation % 180 == 0) ? m.height : m.width;
      final refresh = m.refresh > 0 ? m.refresh : 60.0;

      final posX = m.x < 0 ? 0 : m.x.toInt();
      final posY = m.y < 0 ? 0 : m.y.toInt();
      final transform = m.rotation == 0 ? 'normal' : m.rotation.toString();

      buffer.writeln(
        "    output '${m.id}' enable scale ${m.scale.toStringAsFixed(2)} "
        "mode ${baseW.toInt()}x${baseH.toInt()}@${formatHz(refresh)}Hz "
        "transform $transform position $posX,$posY",
      );
    }

    if (options.injectSwayWorkspaceExec) {
      final enabledMons = mons.where((m) => m.enabled).toList();
      final tmpBase = enabledMons.length + 1;
      for (var i = 0; i < enabledMons.length; i++) {
        final m = enabledMons[i];
        buffer.writeln(
          "    exec swaymsg \"workspace ${tmpBase + i} output '${m.id}'; "
          "workspace ${tmpBase + i}\"",
        );
      }
      for (var i = 0; i < enabledMons.length; i++) {
        final m = enabledMons[i];
        buffer.writeln(
          "    exec swaymsg \"workspace ${i + 1} output '${m.id}'; "
          "workspace ${i + 1}\"",
        );
      }
    }

    if (options.writeCurrentProfileMarker) {
      buffer.writeln(
        "    exec echo \"${profile.name}\" > ~/.current_kanshi_profile",
      );
    }

    buffer.writeln("}\n");
  }

  static MonitorTileData _sanitizeMonitor(
      MonitorTileData m, double offsetX, double offsetY) {
    final posX = (m.x + offsetX) < 0 ? 0 : (m.x + offsetX).toInt();
    final posY = (m.y + offsetY) < 0 ? 0 : (m.y + offsetY).toInt();

    final bestMode = _pickBestMode(m, m.modes);

    final baseW = (m.rotation % 180 == 0) ? bestMode.width : bestMode.height;
    final baseH = (m.rotation % 180 == 0) ? bestMode.height : bestMode.width;
    final refresh = bestMode.refresh > 0 ? bestMode.refresh : 60.0;

    final orientation = (m.rotation % 180 == 0) ? 'landscape' : 'portrait';
    final resolution = '${baseW.toInt()}x${baseH.toInt()}';

    return m.copyWith(
      x: posX.toDouble(),
      y: posY.toDouble(),
      width: baseW,
      height: baseH,
      refresh: refresh,
      resolution: resolution,
      orientation: orientation,
      rotation: m.rotation % 360,
      scale: m.scale == 0 ? 1.0 : m.scale,
      id: m.id.trim(),
      manufacturer: m.manufacturer.trim(),
    );
  }

  static MonitorMode _pickBestMode(
    MonitorTileData monitor,
    List<MonitorMode> modes,
  ) {
    if (modes.isEmpty) {
      return MonitorMode(
        width: monitor.width,
        height: monitor.height,
        refresh: monitor.refresh > 0 ? monitor.refresh : 60,
      );
    }

    final desiredWidth =
        (monitor.rotation % 180 == 0) ? monitor.width : monitor.height;
    final desiredHeight =
        (monitor.rotation % 180 == 0) ? monitor.height : monitor.width;
    final desiredRefresh = monitor.refresh;

    var best = modes.first;
    var bestScore = 1e12;
    for (final m in modes) {
      final dw = (m.width - desiredWidth).abs().round();
      final dh = (m.height - desiredHeight).abs().round();
      final dr = (m.refresh - desiredRefresh).abs();
      final score = dw * 2000 + dh * 2000 + dr * 10;
      if (score < bestScore) {
        bestScore = score;
        best = m;
      }
      if (dw == 0 && dh == 0 && dr < 0.01) {
        best = m;
        break;
      }
    }
    return best;
  }

  static String formatHz(double hz) {
    final isInt = (hz - hz.round()).abs() < 0.01;
    return isInt ? hz.round().toString() : hz.toStringAsFixed(3);
  }
}
