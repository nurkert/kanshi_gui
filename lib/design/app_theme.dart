import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/tokens.dart';

/// Builds the app's [ThemeData] from [AppColors] and the token scales.
///
/// Every control family is themed here, centrally, and that is the point.
/// Dropdowns, menus and dialogs render into their own overlay: they inherit
/// nothing from what was styled on the canvas or on a tile, so leaving them on
/// Material defaults is exactly how they fell out of the app's visual language.
/// Styling them at the call site does not fix it either — it fixes one call
/// site, and the next feature adds another.
///
/// The rule this file exists to enforce: a widget may choose *which* control
/// to use; it may not decide what that control looks like.
class AppTheme {
  AppTheme._();

  static ThemeData build(AppColors c) {
    final scheme = _scheme(c);
    final text = _textTheme(c);
    final base = ThemeData(
      useMaterial3: true,
      brightness: c.brightness,
      colorScheme: scheme,
      textTheme: text,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      // Denser than Material's default, which is tuned for touch. This is a
      // pointer-driven tool on a desktop.
      visualDensity: VisualDensity.compact,
      splashFactory: NoSplash.splashFactory,
    );

    final hairlineBorder = OutlineInputBorder(
      borderRadius: R.controlR,
      borderSide: BorderSide(color: c.hairline, width: Borders.hairline),
    );

    return base.copyWith(
      dividerTheme: DividerThemeData(color: c.hairline, space: 1, thickness: 1),

      // ── Overlay surfaces ───────────────────────────────────────────────
      // The ones that used to look like a different application.
      menuTheme: MenuThemeData(style: _menuStyle(c)),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: _menuStyle(c),
        textStyle: text.bodyMedium,
        inputDecorationTheme: InputDecorationTheme(
          isDense: true,
          filled: true,
          fillColor: c.surfaceRaised,
          border: hairlineBorder,
          enabledBorder: hairlineBorder,
          focusedBorder: OutlineInputBorder(
            borderRadius: R.controlR,
            borderSide: BorderSide(color: c.accent, width: Borders.ring),
          ),
          contentPadding: const EdgeInsets.symmetric(
              horizontal: Sp.x3, vertical: Sp.x2),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: c.scrim,
        textStyle: text.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: R.cardR,
          side: BorderSide(color: c.hairline),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: R.chipR),
          ),
          textStyle: WidgetStatePropertyAll(text.bodyMedium),
          foregroundColor: WidgetStatePropertyAll(c.textPrimary),
          overlayColor: WidgetStatePropertyAll(c.accentSoft),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: R.sheetR,
          side: BorderSide(color: c.hairline),
        ),
        titleTextStyle: T.heading.copyWith(color: c.textPrimary),
        contentTextStyle: T.body.copyWith(color: c.textSecondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(R.sheet)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          borderRadius: R.chipR,
          border: Border.all(color: c.hairline),
        ),
        textStyle: T.caption.copyWith(color: c.textPrimary),
        waitDuration: const Duration(milliseconds: 500),
      ),

      // ── In-page controls ───────────────────────────────────────────────
      cardTheme: CardThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: R.cardR,
          side: BorderSide(color: c.hairline),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: _filledStyle(c, text)),
      textButtonTheme: TextButtonThemeData(style: _textStyle(c, text)),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _textStyle(c, text).copyWith(
          side: WidgetStatePropertyAll(BorderSide(color: c.hairlineStrong)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(c.textSecondary),
          overlayColor: WidgetStatePropertyAll(c.accentSoft),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: R.chipR),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: R.controlR,
              side: BorderSide(color: c.hairlineStrong),
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? c.accentSoft
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? c.textPrimary
                : c.textSecondary,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: c.surfaceRaised,
        border: hairlineBorder,
        enabledBorder: hairlineBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: R.controlR,
          borderSide: BorderSide(color: c.accent, width: Borders.ring),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: R.controlR,
          borderSide: BorderSide(color: c.danger),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        hintStyle: T.body.copyWith(color: c.textTertiary),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : c.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : Colors.transparent,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.accent,
        inactiveTrackColor: c.hairlineStrong,
        thumbColor: c.accent,
        overlayColor: c.accentSoft,
        trackHeight: 3,
      ),
      listTileTheme: ListTileThemeData(
        titleTextStyle: T.body.copyWith(color: c.textPrimary),
        subtitleTextStyle: T.caption.copyWith(color: c.textSecondary),
        iconColor: c.textSecondary,
        shape: RoundedRectangleBorder(borderRadius: R.controlR),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.surfaceRaised,
        contentTextStyle: T.label.copyWith(color: c.textPrimary),
        actionTextColor: c.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: R.cardR,
          side: BorderSide(color: c.hairline),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: T.heading.copyWith(color: c.textPrimary),
        iconTheme: IconThemeData(color: c.textSecondary),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.hairlineStrong,
      ),
    );
  }

  static MenuStyle _menuStyle(AppColors c) => MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surfaceRaised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(c.scrim),
        elevation: const WidgetStatePropertyAll(8),
        padding:
            const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: Sp.x1)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: R.cardR,
            side: BorderSide(color: c.hairline),
          ),
        ),
      );

  static ButtonStyle _filledStyle(AppColors c, TextTheme text) => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? c.hairlineStrong
              : c.accent,
        ),
        foregroundColor: const WidgetStatePropertyAll(Colors.white),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: R.controlR),
        ),
      );

  static ButtonStyle _textStyle(AppColors c, TextTheme text) => ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? c.textTertiary
              : c.textSecondary,
        ),
        overlayColor: WidgetStatePropertyAll(c.accentSoft),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: R.controlR),
        ),
      );

  static TextTheme _textTheme(AppColors c) => TextTheme(
        headlineMedium: T.display.copyWith(color: c.textPrimary),
        titleLarge: T.title.copyWith(color: c.textPrimary),
        titleMedium: T.heading.copyWith(color: c.textPrimary),
        bodyLarge: T.body.copyWith(color: c.textPrimary),
        bodyMedium: T.body.copyWith(color: c.textPrimary),
        labelLarge: T.label.copyWith(color: c.textPrimary),
        labelMedium: T.caption.copyWith(color: c.textSecondary),
        labelSmall: T.micro.copyWith(color: c.textTertiary),
      );

  /// The Material scheme, derived from the tokens rather than the other way
  /// round. Anything the app has not themed explicitly still lands on our
  /// colours instead of Material's tonal defaults.
  static ColorScheme _scheme(AppColors c) => ColorScheme(
        brightness: c.brightness,
        primary: c.accent,
        onPrimary: Colors.white,
        secondary: c.accent,
        onSecondary: Colors.white,
        error: c.danger,
        onError: Colors.white,
        surface: c.surface,
        onSurface: c.textPrimary,
        surfaceContainerLowest: c.bg,
        surfaceContainerLow: c.bg,
        surfaceContainer: c.surface,
        surfaceContainerHigh: c.surfaceRaised,
        surfaceContainerHighest: c.surface,
        outline: c.hairlineStrong,
        outlineVariant: c.hairline,
        scrim: c.scrim,
      );
}
