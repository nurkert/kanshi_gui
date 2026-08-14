/// The design tokens. One place, literal values, no derivation from Material's
/// tonal palette.
///
/// Before this, the app carried eight different corner radii, nine ad-hoc font
/// sizes, roughly twenty spacing values and a dozen hardcoded hex colours,
/// spread across the widgets that happened to need them. Nothing was wrong
/// with any single number; the problem was that no two agreed, and a new
/// surface had nothing to copy from except whichever neighbour was nearest.
///
/// Radii in particular are expected to move: the roadmap's M10 revises them
/// downward after a design review, toward a more angular language. That is a
/// change to this file and nothing else, which is the entire reason the layer
/// exists.
library;

import 'dart:math' show sqrt;

import 'package:flutter/material.dart';

/// Spacing. A 4pt scale, seven steps, and no others.
class Sp {
  Sp._();
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x12 = 48;

  /// Fixed band heights of the main window.
  static const double titleBar = 56;
  static const double assuranceLine = 36;
  static const double shelf = 78;
  static const double stripSuggest = 44;
  static const double stripExpanded = 132;

  /// Breathing room between the arrangement and the canvas edge.
  static const double canvasMargin = 48;
}

/// Corner radii.
///
/// Effectively one value: a 2px chamfer, with 3px reserved for the largest
/// surfaces. Not a scale so much as a decision to stop having one.
///
/// The app draws rectangles with hard pixel coordinates and sits beside a
/// tiling window manager. Rounded chrome fights both: a 14px card corner
/// next to a monitor tile is the app disagreeing with itself about whether
/// this is a precision instrument or a phone. A chamfer keeps edges legible
/// where two surfaces meet without pretending to be soft.
///
/// Everything reads from here, so this paragraph is the only place the
/// decision lives.
class R {
  R._();

  /// A genuinely square corner, for anything that meets another edge flush.
  static const double square = 0;

  static const double chip = 2;
  static const double control = 2;
  static const double screen = 2;
  static const double card = 2;
  static const double sheet = 3;

  static const BorderRadius squareR = BorderRadius.zero;

  static const BorderRadius chipR = BorderRadius.all(Radius.circular(chip));
  static const BorderRadius controlR =
      BorderRadius.all(Radius.circular(control));
  static const BorderRadius screenR = BorderRadius.all(Radius.circular(screen));
  static const BorderRadius cardR = BorderRadius.all(Radius.circular(card));
  static const BorderRadius sheetR = BorderRadius.all(Radius.circular(sheet));
}

/// Type scale. Sizes and weights only — colour comes from [AppColors].
class T {
  T._();
  static const TextStyle display = TextStyle(
      fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.2, height: 1.0);
  static const TextStyle title = TextStyle(
      fontSize: 20, fontWeight: FontWeight.w600, letterSpacing: -0.1, height: 1.2);
  static const TextStyle heading =
      TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.3);
  static const TextStyle body =
      TextStyle(fontSize: 15, fontWeight: FontWeight.w400, height: 1.35);
  static const TextStyle label =
      TextStyle(fontSize: 13, fontWeight: FontWeight.w500, height: 1.3);
  static const TextStyle caption = TextStyle(
      fontSize: 12, fontWeight: FontWeight.w400, letterSpacing: 0.1, height: 1.3);

  /// Tabular figures: resolutions, positions and port names sit in columns
  /// and must not jitter as digits change.
  static const TextStyle mono = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const TextStyle micro = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Semantic colours for one brightness.
///
/// Semantic, not literal: widgets ask for `screenFillSelected`, never for a
/// hex. That is what makes the light theme reach the whole app instead of the
/// third of it it used to cover — the canvas, the header and the tile text
/// were pinned to dark values regardless of the theme.
class AppColors {
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surfaceRaised;
  final Color screenFill;
  final Color screenFillSelected;
  final Color screenFillOff;
  final Color hairline;
  final Color hairlineStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color ok;
  final Color attention;

  /// Screens showing the same picture as another. A distinct hue rather than
  /// the accent: mirroring is a relationship between two screens, not a
  /// selection, and reusing the accent made the two read as the same state.
  final Color mirror;
  final Color danger;
  final Color scrim;

  const AppColors({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.screenFill,
    required this.screenFillSelected,
    required this.screenFillOff,
    required this.hairline,
    required this.hairlineStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.ok,
    required this.attention,
    required this.mirror,
    required this.danger,
    required this.scrim,
  });

  bool get isDark => brightness == Brightness.dark;

  Color get accentSoft => accent.withValues(alpha: 0.16);

  /// The accent as an outline on top of [accentSoft] — a filled chip that
  /// still has to read as a distinct object next to its neighbours. Full
  /// strength would make a row of them vibrate.
  Color get accentLine => accent.withValues(alpha: 0.4);

  /// The accent comes from sway's `client.focused` when it can be read, so
  /// the app agrees with the window manager it sits next to. [fallback] is
  /// used when it cannot.
  static const Color fallbackAccent = Color(0xFF4C8DFF);

  static AppColors dark(Color accent) => AppColors(
        brightness: Brightness.dark,
        bg: const Color(0xFF0F1114),
        surface: const Color(0xFF16181D),
        surfaceRaised: const Color(0xFF1E2127),
        screenFill: const Color(0xFF23262D),
        screenFillSelected: const Color(0xFF2A2E36),
        screenFillOff: const Color(0xFF1A1C21),
        hairline: const Color(0x14FFFFFF),
        hairlineStrong: const Color(0x24FFFFFF),
        textPrimary: const Color(0xFFE8EAED),
        textSecondary: const Color(0x9EE8EAED),
        textTertiary: const Color(0x61E8EAED),
        accent: accent,
        ok: const Color(0xFF3FBF7F),
        attention: const Color(0xFFE8A33D),
        mirror: const Color(0xFF4FC3F7),
        danger: const Color(0xFFE5544B),
        scrim: const Color(0x66000000),
      );

  static AppColors light(Color accent) => AppColors(
        brightness: Brightness.light,
        bg: const Color(0xFFF5F6F8),
        surface: const Color(0xFFFFFFFF),
        surfaceRaised: const Color(0xFFFFFFFF),
        screenFill: const Color(0xFFFFFFFF),
        // Distinguished by its ring, not by its fill: on white, a tinted
        // selection fill reads as "disabled" rather than "chosen".
        screenFillSelected: const Color(0xFFFFFFFF),
        screenFillOff: const Color(0xFFEDEEF1),
        hairline: const Color(0x17000000),
        hairlineStrong: const Color(0x29000000),
        textPrimary: const Color(0xFF15171A),
        textSecondary: const Color(0x9E15171A),
        textTertiary: const Color(0x6B15171A),
        accent: accent,
        ok: const Color(0xFF1E9E5F),
        attention: const Color(0xFFB36B00),
        mirror: const Color(0xFF0277BD),
        danger: const Color(0xFFC4362C),
        scrim: const Color(0x4715171A),
      );
}

/// Border widths and the dashed patterns the canvas uses.
class Borders {
  Borders._();
  static const double hairline = 1;

  /// The shared edge between two flush screens.
  static const double seam = 2;

  /// Selection.
  static const double ring = 2;

  /// Drift ghosts and screens that are remembered but not connected.
  static const double ghost = 1.5;
  static const double ghostDash = 6;
  static const double ghostGap = 4;
}

/// Motion. A closed list — eight durations and no more.
///
/// Every one is expressible with Flutter's implicit-animation widgets, so the
/// app needs no AnimationControllers. If an effect needs a ninth entry or a
/// controller, it does not ship.
class Motion {
  Motion._();
  static const Duration hover = Duration(milliseconds: 80);
  static const Duration snapCatch = Duration(milliseconds: 90);
  static const Duration tick = Duration(milliseconds: 120);
  static const Duration strip = Duration(milliseconds: 180);
  static const Duration crossfade = Duration(milliseconds: 200);
  static const Duration settle = Duration(milliseconds: 220);

  /// App-initiated changes are slower than user-initiated ones, and the
  /// difference carries meaning: a screen arriving is something that happened
  /// TO you, and you should not be able to miss it.
  static const Duration arrive = Duration(milliseconds: 300);
  static const Duration flight = Duration(milliseconds: 320);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasised = Curves.easeInOutCubic;
  static const Curve overshoot = Curves.easeOutBack;

  /// Below this, a "working" state is never rendered — routine saves and
  /// applies finish well inside it and the status line stays still.
  static const Duration workingThreshold = Duration(milliseconds: 400);
}

/// Values the app derives rather than asks the user to configure.
class Derived {
  Derived._();

  /// Snap distance scales with the canvas so it feels identical whether the
  /// window is small or maximised. Alt suspends it.
  ///
  /// Replaces the `snapDistance` preference: a number the user had to guess
  /// at, in pixels, that then felt wrong at a different window size.
  static double snapDistance(Size canvas) {
    final diagonal = sqrt(
        canvas.width * canvas.width + canvas.height * canvas.height);
    return (0.02 * diagonal).clamp(14.0, 240.0);
  }
}
