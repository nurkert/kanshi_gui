import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/// Builds the cross-platform menu bar and routes platform-native menu
/// callbacks (delivered via the `kanshi_gui/native_menu` MethodChannel)
/// to the [KanshiController]. Action strings must remain stable to keep
/// the bundled C++ menu intact.
class AppMenu extends StatefulWidget {
  final KanshiController controller;
  final Widget child;
  final Future<void> Function() onShowLogs;
  final Future<void> Function() onShowHelp;

  const AppMenu({
    super.key,
    required this.controller,
    required this.child,
    required this.onShowLogs,
    required this.onShowHelp,
  });

  @override
  State<AppMenu> createState() => _AppMenuState();
}

class _AppMenuState extends State<AppMenu> {
  static const MethodChannel _nativeMenuChannel =
      MethodChannel('kanshi_gui/native_menu');

  @override
  void initState() {
    super.initState();
    _nativeMenuChannel.setMethodCallHandler(_handle);
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'select') return;
    final action = call.arguments as String?;
    switch (action) {
      case 'saveRestart':
        _toast(await widget.controller.reloadAndApply());
        break;
      case 'saveProfiles':
        _toast(await widget.controller.saveProfilesOnly());
        break;
      case 'reload':
        _toast(await widget.controller.reloadOnly());
        break;
      case 'enableAll':
        _toast(await widget.controller.enableAllOutputs());
        break;
      case 'restartKanshi':
        _toast(await widget.controller.restartCompositorService());
        break;
      case 'restoreBackup':
        _toast(await widget.controller.restoreBackupAndApply());
        break;
      case 'showLogs':
        await widget.onShowLogs();
        break;
      case 'showHelp':
        await widget.onShowHelp();
        break;
    }
  }

  void _toast(OpResult r) {
    if (!mounted || r.message == null) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(r.message!)));
  }

  @override
  Widget build(BuildContext context) {
    return PlatformMenuBar(
      menus: [
        PlatformMenu(
          label: 'File',
          menus: [
            PlatformMenuItem(
              label: 'Save & restart kanshi',
              onSelected: () async => _toast(
                  await widget.controller.reloadAndApply()),
            ),
            PlatformMenuItem(
              label: 'Save profiles only',
              onSelected: () async =>
                  _toast(await widget.controller.saveProfilesOnly()),
            ),
            PlatformMenuItem(
              label: 'Reload outputs & profiles',
              onSelected: () async =>
                  _toast(await widget.controller.reloadOnly()),
            ),
          ],
        ),
        PlatformMenu(
          label: 'Actions',
          menus: [
            PlatformMenuItem(
              label: 'Enable all displays',
              onSelected: () async =>
                  _toast(await widget.controller.enableAllOutputs()),
            ),
            PlatformMenuItem(
              label: 'Restart kanshi',
              onSelected: () async =>
                  _toast(await widget.controller.restartCompositorService()),
            ),
            PlatformMenuItem(
              label: 'Restore backup & apply',
              onSelected: () async =>
                  _toast(await widget.controller.restoreBackupAndApply()),
            ),
            PlatformMenuItem(
              label: 'Show logs',
              onSelected: widget.onShowLogs,
            ),
          ],
        ),
        PlatformMenu(
          label: 'Help',
          menus: [
            PlatformMenuItem(
              label: 'Show tips',
              onSelected: widget.onShowHelp,
            ),
          ],
        ),
      ],
      child: widget.child,
    );
  }
}
