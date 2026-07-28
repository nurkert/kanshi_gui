import 'package:flutter/material.dart';
import 'package:kanshi_gui/design/tokens.dart';

/// Reaches the semantic colours from a widget.
///
/// Flutter carries [ColorScheme] through the tree but not our token set, and
/// mapping every semantic role onto a Material slot would lose the ones
/// Material has no name for — `screenFillOff`, `hairlineStrong`, `attention`.
/// So the palette is rebuilt from the inherited brightness and accent, which
/// keeps `context.colors` correct under a theme switch without a second
/// InheritedWidget to keep in sync.
extension ThemeContext on BuildContext {
  AppColors get colors {
    final theme = Theme.of(this);
    final accent = theme.colorScheme.primary;
    return theme.brightness == Brightness.dark
        ? AppColors.dark(accent)
        : AppColors.light(accent);
  }
}
