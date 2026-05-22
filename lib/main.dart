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

  /// Seed for the Material 3 colour scheme. Falls back to the historical
  /// teal when there's neither an override nor a Sway-derived accent.
  Color get _seed => _accent ?? const Color(0xFF26A69A);

  /// Called by the settings page after an appearance change so the
  /// MaterialApp (theme mode, accent) rebuilds without an app restart.
  void _onAppearanceChanged() => setState(() {});

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // The canvas/editor chrome reads better tight; nudge the global
      // visual density a touch denser than Material's airy default.
      visualDensity: VisualDensity.comfortable,
    );
    return base.copyWith(
      // Frosted surfaces float over the dark canvas; kill the default
      // tonal elevation tint so cards/sheets stay crisp instead of muddy.
      cardTheme: base.cardTheme.copyWith(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        space: 1,
      ),
      // Unify every menu/dropdown surface: rounded, raised, on a clearly
      // distinct container colour so they read as floating panels rather
      // than flat default boxes. Covers MenuAnchor (tile three-dot menu,
      // presets), PopupMenuButton, and DropdownMenu/DropdownButtonFormField.
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor:
              WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(8),
          padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 6)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor:
              WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
    );
  }

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
