// lib/main.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kanshi_gui/design/app_theme.dart';
import 'package:kanshi_gui/design/tokens.dart';
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
  // Load settings BEFORE constructing the controller: the workspace-
  // management opt-in feeds into the controller's effective write options,
  // and init() runs the workspace-placement apply pass. Building the
  // controller first would let a fresh-install first launch reshuffle
  // workspaces before we even know the user opted out.
  final settings = await AppSettings.load();
  final controller = KanshiController(
    monitors: monitors,
    config: ConfigService(
      // Null = the standard ~/.config/kanshi/config (advanced override).
      configPath: settings.kanshiConfigPath,
      writeOptions: monitors.writeOptions,
      maxBackups: settings.maxBackups,
    ),
  );
  // Push the user's preferences in BEFORE init() so the first config save
  // already reflects them (and a fresh-install opt-out never reshuffles).
  controller.applyStartupSettings(settings);
  await controller.init();

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

  ThemeMode get _themeMode {
    switch (widget.settings.themeChoice) {
      case AppThemeChoice.system:
        return ThemeMode.system;
      case AppThemeChoice.light:
        return ThemeMode.light;
      case AppThemeChoice.dark:
        return ThemeMode.dark;
    }
  }

  /// Effective accent: an explicit settings override wins, otherwise the
  /// Sway-config-derived colour detected at startup.
  Color? get _accent => widget.settings.accentArgb != null
      ? Color(widget.settings.accentArgb!)
      : widget.accent;

  /// The accent every surface is tinted from. Sway's `client.focused` when it
  /// could be read, so the app agrees with the window manager it sits beside.
  Color get _seed => _accent ?? AppColors.fallbackAccent;

  /// Called by the settings page after an appearance change so the
  /// MaterialApp (theme mode, accent) rebuilds without an app restart.
  void _onAppearanceChanged() => setState(() {});

  /// The whole theme comes from the token layer.
  ///
  /// Not `ColorScheme.fromSeed` any more: that derived every surface from
  /// Material's tonal algorithm, so the app's colours were whatever the
  /// algorithm produced from one accent — and menus, dialogs and dropdowns,
  /// which render in their own overlay and inherit nothing from the canvas,
  /// were the most visible casualties. See [AppTheme].
  ThemeData _theme(Brightness brightness) => AppTheme.build(
        brightness == Brightness.dark
            ? AppColors.dark(_seed)
            : AppColors.light(_seed),
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kanshi GUI',
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: _themeMode,
      home: _showWizard
          ? FirstRunWizard(
              controller: widget.controller,
              settings: widget.settings,
              onDone: () => setState(() => _showWizard = false),
            )
          : HomePage(
              controller: widget.controller,
              settings: widget.settings,
              activeAccent: _accent,
              onAppearanceChanged: _onAppearanceChanged,
            ),
    );
  }
}
