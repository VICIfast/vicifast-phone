import 'package:flutter/material.dart';

/// A state's two colors: the strong one for words and dots, the soft one for fills.
@immutable
class StateTone {
  const StateTone(this.fg, this.bg);
  final Color fg;
  final Color bg;

  static StateTone lerp(StateTone a, StateTone b, double t) =>
      StateTone(Color.lerp(a.fg, b.fg, t)!, Color.lerp(a.bg, b.bg, t)!);
}

/// The app's palette. Buttons and text stay neutral; color only ever means agent state.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.card,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.line,
    required this.line2,
    required this.fill,
    required this.selected,
    required this.primary,
    required this.onPrimary,
    required this.onState,
    required this.ready,
    required this.paused,
    required this.call,
    required this.hold,
    required this.wrap,
    required this.problem,
    required this.accept,
    required this.decline,
  });

  final Color bg;
  final Color card;
  final Color ink;
  final Color ink2;
  final Color muted;
  final Color line;
  final Color line2;
  final Color fill;
  final Color selected;
  final Color primary;
  final Color onPrimary;
  final Color onState;
  final StateTone ready;
  final StateTone paused;
  final StateTone call;
  final StateTone hold;
  final StateTone wrap;
  final StateTone problem;
  final Color accept;
  final Color decline;

  static AppColors light({required bool ios}) => AppColors(
    bg: ios ? const Color(0xFFF2F2F7) : const Color(0xFFF4F6F5),
    card: const Color(0xFFFFFFFF),
    ink: const Color(0xFF121816),
    ink2: const Color(0xFF4B5653),
    muted: const Color(0xFF626D6A),
    line: ios ? const Color(0xFFE1E1E6) : const Color(0xFFE3E8E6),
    line2: const Color(0xFFC9D1CE),
    fill: ios ? const Color(0xFFE9E9EE) : const Color(0xFFECEFF0),
    selected: const Color(0xFFDFE8E5),
    primary: const Color(0xFF131A18),
    onPrimary: const Color(0xFFFFFFFF),
    onState: const Color(0xFFFFFFFF),
    ready: const StateTone(Color(0xFF087A4F), Color(0xFFDCF2E7)),
    paused: const StateTone(Color(0xFF955800), Color(0xFFFBEED6)),
    call: const StateTone(Color(0xFF1D5FD6), Color(0xFFE0E9FC)),
    hold: const StateTone(Color(0xFF7339D8), Color(0xFFECE3FB)),
    wrap: const StateTone(Color(0xFF0A6F80), Color(0xFFDBF0F3)),
    problem: const StateTone(Color(0xFFC8281C), Color(0xFFFDE3E0)),
    accept: const Color(0xFF128A4F),
    decline: const Color(0xFFD9342A),
  );

  static AppColors dark({required bool ios}) => AppColors(
    bg: ios ? const Color(0xFF000000) : const Color(0xFF0E1211),
    card: ios ? const Color(0xFF1C1C1E) : const Color(0xFF19201E),
    ink: const Color(0xFFEDF2F0),
    ink2: const Color(0xFFB6C1BD),
    muted: const Color(0xFF8D9894),
    line: ios ? const Color(0xFF2C2C2E) : const Color(0xFF29312F),
    line2: const Color(0xFF3A4441),
    fill: ios ? const Color(0xFF2C2C2E) : const Color(0xFF232B29),
    selected: const Color(0xFF26352F),
    primary: const Color(0xFFEEF3F1),
    onPrimary: const Color(0xFF0E1211),
    onState: const Color(0xFF08130E),
    ready: const StateTone(Color(0xFF3FCF8F), Color(0xFF10301F)),
    paused: const StateTone(Color(0xFFF2AC3E), Color(0xFF352508)),
    call: const StateTone(Color(0xFF78A4FF), Color(0xFF15244A)),
    hold: const StateTone(Color(0xFFB590FF), Color(0xFF26183F)),
    wrap: const StateTone(Color(0xFF55C8D8), Color(0xFF0C2C32)),
    problem: const StateTone(Color(0xFFFF6D60), Color(0xFF3A1411)),
    accept: const Color(0xFF1FA463),
    decline: const Color(0xFFD9342A),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      bg: c(bg, other.bg),
      card: c(card, other.card),
      ink: c(ink, other.ink),
      ink2: c(ink2, other.ink2),
      muted: c(muted, other.muted),
      line: c(line, other.line),
      line2: c(line2, other.line2),
      fill: c(fill, other.fill),
      selected: c(selected, other.selected),
      primary: c(primary, other.primary),
      onPrimary: c(onPrimary, other.onPrimary),
      onState: c(onState, other.onState),
      ready: StateTone.lerp(ready, other.ready, t),
      paused: StateTone.lerp(paused, other.paused, t),
      call: StateTone.lerp(call, other.call, t),
      hold: StateTone.lerp(hold, other.hold, t),
      wrap: StateTone.lerp(wrap, other.wrap, t),
      problem: StateTone.lerp(problem, other.problem, t),
      accept: c(accept, other.accept),
      decline: c(decline, other.decline),
    );
  }
}

/// Spacing on a 4-point scale.
abstract final class Gap {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Minimum touch target: 48dp on Android, 44pt on iOS.
abstract final class Touch {
  static double min(BuildContext c) => isIOS(c) ? 44 : 48;
}

bool isIOS(BuildContext c) => Theme.of(c).platform == TargetPlatform.iOS;

extension AppTheme on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
  bool get ios => isIOS(this);

  /// Card radius: rounder on Android (Material 3), tighter on iOS (inset grouped).
  double get cardRadius => ios ? 12 : 18;
}

/// Digits that line up, for timers and counts.
const tabular = [FontFeature.tabularFigures()];
