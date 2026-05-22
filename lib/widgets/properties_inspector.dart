import 'package:flutter/material.dart';
import 'package:kanshi_gui/models/monitor_mode.dart';
import 'package:kanshi_gui/models/monitor_tile_data.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// Right-hand inspector for the selected output. Replaces the fiddly
/// right-click submenus with proper controls (resolution, scale, rotation,
/// mirror, enable). Position stays a drag affair on the canvas, shown here
/// read-only. Edits go straight through the controller (same immediate
/// behaviour as the canvas), and any error surfaces via [onResult].
class PropertiesInspector extends StatelessWidget {
  static const double width = 300;

  final KanshiController controller;
  final String monitorId;
  final bool mirrorEnabled;
  final VoidCallback onClose;
  final void Function(OpResult) onResult;

  const PropertiesInspector({
    super.key,
    required this.controller,
    required this.monitorId,
    required this.mirrorEnabled,
    required this.onClose,
    required this.onResult,
  });

  static const _scaleValues = <double>[
    1.0, 1.25, 1.333, 1.5, 1.75, 2.0, 2.5, 3.0,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = controller.activeMonitors
        .where((m) => m.id == monitorId)
        .firstOrNull;
    if (m == null) return const SizedBox.shrink();

    final isMirrorDest = m.mirrorOf != null;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          left: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Row(
            children: [
              Icon(Icons.desktop_windows, color: scheme.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  m.id,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Close',
                onPressed: onClose,
              ),
            ],
          ),
          if (m.manufacturer.isNotEmpty && m.manufacturer != m.id)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(m.manufacturer,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      )),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Enabled'),
            value: m.enabled,
            onChanged: (v) async => onResult(
                await controller.toggleEnabled(m.id, v)),
          ),
          if (m.enabled && !isMirrorDest) ...[
            const Divider(),
            _label(context, 'Resolution & refresh'),
            _resolutionDropdown(context, m),
            const SizedBox(height: 16),
            _label(context, 'Scale'),
            _scaleDropdown(context, m),
            const SizedBox(height: 16),
            _label(context, 'Rotation'),
            _rotationButtons(context, m),
            if (mirrorEnabled && controller.supportsMirror) ...[
              const SizedBox(height: 16),
              _label(context, 'Mirror onto'),
              _mirrorDropdown(context, m),
            ],
            const SizedBox(height: 16),
            _label(context, 'Position'),
            Text(
              '${m.x.toInt()}, ${m.y.toInt()}   ·   drag on the canvas to move',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
          if (isMirrorDest)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Mirroring ${m.mirrorOf} — release the mirror to edit this '
                'output independently.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )),
      );

  Widget _resolutionDropdown(BuildContext context, MonitorTileData m) {
    // Dedupe modes by label, sort by area then refresh, both descending.
    final seen = <String>{};
    final modes = [
      for (final mode in m.modes)
        if (seen.add(mode.label)) mode,
    ]..sort((a, b) {
        final areaA = a.width * a.height;
        final areaB = b.width * b.height;
        if (areaA != areaB) return areaB.compareTo(areaA);
        return b.refresh.compareTo(a.refresh);
      });
    if (modes.isEmpty) {
      return Text('${m.resolution} @ ${m.refresh.round()}Hz',
          style: Theme.of(context).textTheme.bodyMedium);
    }
    // Match the current mode by resolution + refresh.
    MonitorMode? current;
    for (final mode in modes) {
      final landscapeW = m.rotation % 180 == 0 ? m.width : m.height;
      final landscapeH = m.rotation % 180 == 0 ? m.height : m.width;
      if (mode.width.toInt() == landscapeW.toInt() &&
          mode.height.toInt() == landscapeH.toInt() &&
          (mode.refresh - m.refresh).abs() < 0.5) {
        current = mode;
        break;
      }
    }
    return DropdownButtonFormField<MonitorMode>(
      initialValue: current,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      items: [
        for (final mode in modes)
          DropdownMenuItem(value: mode, child: Text(mode.label)),
      ],
      onChanged: (mode) async {
        if (mode != null) onResult(await controller.applyMode(m.id, mode));
      },
    );
  }

  Widget _scaleDropdown(BuildContext context, MonitorTileData m) {
    // Offer the common snap scales plus the current value if it isn't one.
    final values = [..._scaleValues];
    if (!values.any((v) => (v - m.scale).abs() < 0.01)) {
      values.add(m.scale);
      values.sort();
    }
    return DropdownButtonFormField<double>(
      initialValue: values.firstWhere((v) => (v - m.scale).abs() < 0.01,
          orElse: () => m.scale),
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      items: [
        for (final v in values)
          DropdownMenuItem(value: v, child: Text('${v.toStringAsFixed(2)}×')),
      ],
      onChanged: (v) async {
        if (v == null) return;
        controller.scaleMonitor(m.id, v, committing: true);
        final updated = controller.activeMonitors
            .firstWhere((x) => x.id == m.id);
        onResult(await controller.pushLiveApply(updated));
      },
    );
  }

  Widget _rotationButtons(BuildContext context, MonitorTileData m) {
    return SegmentedButton<int>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: 0, label: Text('0°')),
        ButtonSegment(value: 90, label: Text('90°')),
        ButtonSegment(value: 180, label: Text('180°')),
        ButtonSegment(value: 270, label: Text('270°')),
      ],
      selected: {m.rotation % 360},
      onSelectionChanged: (sel) {
        controller.updateMonitor(m.copyWith(rotation: sel.first));
      },
    );
  }

  Widget _mirrorDropdown(BuildContext context, MonitorTileData m) {
    final sources = controller.activeMonitors
        .where((o) => o.id != m.id && o.enabled && o.mirrorOf == null)
        .toList();
    return DropdownButtonFormField<String?>(
      initialValue: m.mirrorOf,
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('None (independent)')),
        for (final s in sources)
          DropdownMenuItem(value: s.id, child: Text(s.id)),
      ],
      onChanged: (srcId) async =>
          onResult(await controller.setMirror(m.id, srcId)),
    );
  }
}
