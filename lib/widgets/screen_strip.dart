import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/theme_context.dart';
import 'package:kanshi_gui/design/tokens.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// The controls for the selected screen, in a band under the canvas.
///
/// Replaces a 300px right-hand inspector. The arrangement is a wide, short
/// thing and horizontal pixels are the scarce resource, so taking a third of
/// the width to show six controls was the wrong axis. At rest the band has
/// zero height: nothing selected, nothing shown, and no permanent toolbar.
///
/// Every row is costed against the 900px minimum window width so it cannot
/// wrap into an overflow menu — a control that hides itself at small sizes is
/// a control the user cannot find.
class ScreenStrip extends StatelessWidget {
  final KanshiController controller;

  /// Selected output, or null when the band should collapse.
  final String? monitorId;
  final bool mirrorEnabled;
  final VoidCallback onClose;
  final void Function(OpResult) onResult;

  const ScreenStrip({
    super.key,
    required this.controller,
    required this.monitorId,
    required this.mirrorEnabled,
    required this.onClose,
    required this.onResult,
  });

  @override
  Widget build(BuildContext context) {
    final id = monitorId;
    final m = id == null
        ? null
        : controller.activeMonitors.where((e) => e.id == id).firstOrNull;

    return AnimatedSize(
      duration: Motion.strip,
      curve: Motion.standard,
      alignment: Alignment.topCenter,
      child: m == null ? const SizedBox(width: double.infinity) : _body(context, m),
    );
  }

  Widget _body(BuildContext context, MonitorTileData m) {
    final c = context.colors;
    final isMirrorDestination = m.mirrorOf != null;

    return Material(
      color: c.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x3, Sp.x2, Sp.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  m.manufacturer.isEmpty || m.manufacturer == m.id
                      ? m.id
                      : m.manufacturer,
                  style: T.label.copyWith(color: c.textPrimary),
                ),
                const SizedBox(width: Sp.x3),
                // The port, in mono and quiet: it is the thing that CHANGES
                // between reboots, so it is a fact to look up rather than the
                // screen's name.
                Text(
                  '${m.id} · at ${m.x.toInt()},${m.y.toInt()}',
                  style: T.mono.copyWith(color: c.textTertiary),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onClose,
                ),
              ],
            ),
            const SizedBox(height: Sp.x2),
            if (isMirrorDestination &&
                controller.mirrorRunner.failedDestinations.contains(m.id))
              // The runner gave up: wl-mirror exited three times in thirty
              // seconds. The user reads "mirror" on the tile and sees a bare
              // desktop on the screen; without this line the two never meet.
              Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: c.textSecondary),
                  const SizedBox(width: Sp.x2),
                  Expanded(
                    child: Text(
                      'The mirror stopped: wl-mirror keeps exiting on '
                      '${m.id}.',
                      style: T.caption.copyWith(color: c.textSecondary),
                    ),
                  ),
                  TextButton(
                    onPressed: () async =>
                        onResult(await controller.retryMirror(m.id)),
                    child: const Text('Retry'),
                  ),
                ],
              )
            else if (isMirrorDestination)
              Text(
                'Showing the same picture as ${m.mirrorOf}.',
                style: T.caption.copyWith(color: c.textSecondary),
              )
            else
              Wrap(
                spacing: Sp.x6,
                runSpacing: Sp.x2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _resolution(context, m),
                  _rotation(context, m),
                  _size(context, m),
                  _power(context, m),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _labelled(BuildContext context, String label, Widget child) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: T.caption.copyWith(color: c.textSecondary)),
        const SizedBox(width: Sp.x2),
        child,
      ],
    );
  }

  Widget _resolution(BuildContext context, MonitorTileData m) {
    // Distinct modes, largest first. Duplicates are common — a panel often
    // reports the same geometry at several refresh rates it cannot tell apart.
    final seen = <String>{};
    final modes = [
      for (final mode in m.modes)
        if (seen.add('${mode.width.toInt()}x${mode.height.toInt()}'
            '@${mode.refresh.toStringAsFixed(3)}'))
          mode,
    ]..sort((a, b) {
        final byArea = (b.width * b.height).compareTo(a.width * a.height);
        return byArea != 0 ? byArea : b.refresh.compareTo(a.refresh);
      });
    if (modes.isEmpty) {
      return _labelled(context, 'Resolution',
          Text('${m.width.toInt()} × ${m.height.toInt()}',
              style: T.mono.copyWith(color: context.colors.textSecondary)));
    }

    final landscapeW = m.rotation % 180 == 0 ? m.width : m.height;
    final landscapeH = m.rotation % 180 == 0 ? m.height : m.width;
    final current = modes.where((mode) =>
        mode.width == landscapeW &&
        mode.height == landscapeH &&
        (mode.refresh - m.refresh).abs() < 0.01);

    return _labelled(
      context,
      'Resolution',
      DropdownButtonHideUnderline(
        child: DropdownButton<MonitorMode>(
          value: current.isEmpty ? null : current.first,
          isDense: true,
          items: [
            for (final mode in modes)
              DropdownMenuItem(
                value: mode,
                child: Text(
                  '${mode.width.toInt()} × ${mode.height.toInt()}'
                  '  ·  ${mode.refresh.round()} Hz',
                  style: T.mono,
                ),
              ),
          ],
          onChanged: (mode) async {
            if (mode == null) return;
            onResult(await controller.applyMode(m.id, mode));
          },
        ),
      ),
    );
  }

  Widget _rotation(BuildContext context, MonitorTileData m) {
    const options = <int, IconData>{
      0: Icons.crop_landscape,
      90: Icons.crop_portrait,
      180: Icons.crop_landscape,
      270: Icons.crop_portrait,
    };
    return _labelled(
      context,
      'Rotation',
      SegmentedButton<int>(
        segments: [
          for (final entry in options.entries)
            ButtonSegment(
              value: entry.key,
              icon: Icon(entry.value, size: 16),
              tooltip: '${entry.key}°',
            ),
        ],
        selected: {m.rotation % 360},
        showSelectedIcon: false,
        onSelectionChanged: (sel) =>
            controller.updateMonitor(m.copyWith(rotation: sel.first)),
      ),
    );
  }

  Widget _size(BuildContext context, MonitorTileData m) {
    // "Size", not "scale": what the user is changing is how big everything
    // looks, and the percentage is the number behind that.
    return _labelled(
      context,
      'Size',
      SizedBox(
        width: 210,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                min: 0.5,
                max: 3.0,
                value: m.scale.clamp(0.5, 3.0),
                onChanged: (v) => controller.scaleMonitor(m.id, v),
                onChangeEnd: (v) =>
                    controller.scaleMonitor(m.id, v, committing: true),
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(
                '${(m.scale * 100).round()} %',
                textAlign: TextAlign.right,
                style: T.mono.copyWith(color: context.colors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _power(BuildContext context, MonitorTileData m) {
    return TextButton.icon(
      icon: Icon(m.enabled ? Icons.power_settings_new : Icons.play_arrow,
          size: 16),
      label: Text(m.enabled ? 'Turn off' : 'Turn on'),
      onPressed: () async =>
          onResult(await controller.toggleEnabled(m.id, !m.enabled)),
    );
  }
}
