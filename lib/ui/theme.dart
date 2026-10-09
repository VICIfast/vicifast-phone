import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// System fonts on both platforms: Roboto on Android, San Francisco on iOS.
/// No fontFamily is set, so Flutter picks the platform's own.
ThemeData buildTheme(Brightness brightness, TargetPlatform platform) {
  final ios = platform == TargetPlatform.iOS;
  final c = brightness == Brightness.dark ? AppColors.dark(ios: ios) : AppColors.light(ios: ios);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.primary,
    onPrimary: c.onPrimary,
    secondary: c.ink2,
    onSecondary: c.card,
    error: c.problem.fg,
    onError: c.onState,
    surface: c.bg,
    onSurface: c.ink,
    surfaceContainerLowest: c.card,
    surfaceContainerLow: c.card,
    surfaceContainer: c.card,
    surfaceContainerHigh: c.card,
    surfaceContainerHighest: c.fill,
    secondaryContainer: c.selected,
    onSecondaryContainer: c.ink,
    outline: c.line2,
    outlineVariant: c.line,
  );

  final base = Typography.material2021(platform: platform);
  final textBase = brightness == Brightness.dark ? base.white : base.black;
  final text = textBase
      .apply(bodyColor: c.ink, displayColor: c.ink)
      .copyWith(
        headlineSmall: textBase.headlineSmall?.copyWith(
          fontSize: ios ? 32 : 26,
          fontWeight: ios ? FontWeight.w700 : FontWeight.w400,
          color: c.ink,
        ),
        titleLarge: textBase.titleLarge?.copyWith(
          fontSize: ios ? 20 : 22,
          fontWeight: ios ? FontWeight.w600 : FontWeight.w400,
          color: c.ink,
        ),
        titleMedium: textBase.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: c.ink),
        bodyLarge: textBase.bodyLarge?.copyWith(fontSize: ios ? 17 : 16, color: c.ink),
        bodyMedium: textBase.bodyMedium?.copyWith(fontSize: ios ? 15 : 14, color: c.ink),
        bodySmall: textBase.bodySmall?.copyWith(fontSize: 12.5, color: c.ink2),
        labelLarge: textBase.labelLarge?.copyWith(fontSize: ios ? 17 : 16, fontWeight: FontWeight.w600),
        labelMedium: textBase.labelMedium?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500, color: c.ink2),
        labelSmall: textBase.labelSmall?.copyWith(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.0),
      );

  final buttonShape = ios ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)) : const StadiumBorder();
  final buttonSize = Size.fromHeight(ios ? 50 : 52);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    platform: platform,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    textTheme: text,
    splashFactory: ios ? NoSplash.splashFactory : InkSparkle.splashFactory,
    extensions: [c],
    dividerTheme: DividerThemeData(color: c.line, space: 1, thickness: ios ? 0.5 : 1),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: ios,
      titleTextStyle: text.titleLarge,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonSize,
        shape: buttonShape,
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        disabledBackgroundColor: c.fill,
        disabledForegroundColor: c.ink2,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        shape: buttonShape,
        foregroundColor: c.ink,
        disabledForegroundColor: c.ink2,
        side: BorderSide(color: c.line2),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.ink, textStyle: text.labelLarge?.copyWith(fontSize: 15)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: ios,
      fillColor: c.card,
      border: ios
          ? OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none)
          : const OutlineInputBorder(),
      enabledBorder: ios
          ? OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none)
          : OutlineInputBorder(borderSide: BorderSide(color: c.line2)),
      focusedBorder: ios
          ? OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: c.ink, width: 1.5),
            )
          : OutlineInputBorder(borderSide: BorderSide(color: c.ink, width: 2)),
      floatingLabelBehavior: ios ? FloatingLabelBehavior.never : FloatingLabelBehavior.auto,
      labelStyle: TextStyle(color: ios ? c.muted : c.ink2),
      floatingLabelStyle: TextStyle(color: c.ink),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.bg : c.ink2),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.ink : c.fill),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.ink : c.line2),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.card,
      indicatorColor: c.selected,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStatePropertyAll(text.labelMedium?.copyWith(color: c.ink)),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? c.ink : c.ink2),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: ios && brightness == Brightness.light ? c.bg : c.card,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.line2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(ios ? 14 : 28))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.ink,
      contentTextStyle: text.bodyMedium?.copyWith(color: c.bg),
      actionTextColor: c.bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(ios ? 12 : 8)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: c.selected,
        selectedForegroundColor: c.ink,
        foregroundColor: c.ink2,
        side: BorderSide(color: c.line2),
      ),
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: c.ink,
      scaffoldBackgroundColor: c.bg,
      barBackgroundColor: c.card.withValues(alpha: 0.92),
    ),
  );
}
