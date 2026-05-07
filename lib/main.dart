// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/pages/first_run_wizard.dart';
import 'package:kanshi_gui/pages/home_page.dart';
import 'package:kanshi_gui/services/app_settings.dart';
import 'package:kanshi_gui/services/config_service.dart';
import 'package:kanshi_gui/services/monitor_service.dart';
import 'package:kanshi_gui/services/sway_theme.dart';
import 'package:kanshi_gui/state/kanshi_controller.dart';

/*
 * This file is part of kanshi_gui.
 *
 * kanshi_gui is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * kanshi_gui is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with kanshi_gui. If not, see <https://www.gnu.org/licenses/>.
 */
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Reset any leftover keyboard state that might cause assertion errors
  // when a key down event is received while considered already pressed.
  // ignore: invalid_use_of_visible_for_testing_member
  HardwareKeyboard.instance.clearState();

  final monitors = await MonitorService.detect();
  final controller = KanshiController(
    monitors: monitors,
    config: ConfigService(writeOptions: monitors.writeOptions),
  );
  await controller.init();

  final settings = await AppSettings.load();
  // Best-effort sway accent lookup; null means the sidebar falls back
  // to its built-in teal. We do this once at startup rather than on
  // every rebuild because the sway config rarely changes and an FS
  // watcher would be more code than it's worth.
  final accent = await SwayThemeReader.readAccentColor();

  runApp(KanshiApp(
    controller: controller,
    settings: settings,
    accent: accent,
  ));
}

class KanshiApp extends StatefulWidget {
  final KanshiController controller;
  final AppSettings settings;
  final Color? accent;
  const KanshiApp({
    super.key,
    required this.controller,
    required this.settings,
    this.accent,
  });

  @override
  State<KanshiApp> createState() => _KanshiAppState();
}

class _KanshiAppState extends State<KanshiApp> {
  late bool _showWizard;

  @override
  void initState() {
    super.initState();
    _showWizard = !widget.settings.firstRunDone;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kanshi GUI',
      theme: ThemeData.dark(),
      home: _showWizard
          ? FirstRunWizard(
              controller: widget.controller,
              settings: widget.settings,
              onDone: () => setState(() => _showWizard = false),
            )
          : HomePage(
              controller: widget.controller,
              settings: widget.settings,
              activeAccent: widget.accent,
            ),
    );
  }
}
