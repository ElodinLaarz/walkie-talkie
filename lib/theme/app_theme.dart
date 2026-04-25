import 'package:flutter/material.dart';

/// Color tokens derived from the Frequency design (Linear/Arc minimal).
/// The CSS uses oklch(); these are the closest visually-matched sRGB values.
class FrequencyColors {
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color line;
  final Color line2;
  final Color accent;
  final Color accentSoft;
  final Color accentInk;
  final Color warn;
  final Color warnSoft;
  final Color danger;
  final Color stage;

  const FrequencyColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.line,
    required this.line2,
    required this.accent,
    required this.accentSoft,
    required this.accentInk,
    required this.warn,
    required this.warnSoft,
    required this.danger,
    required this.stage,
  });

  static const FrequencyColors light = FrequencyColors(
    bg: Color(0xFFFAFAFB),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF2F3F4),
    surface3: Color(0xFFEAEBED),
    ink: Color(0xFF1B1D22),
    ink2: Color(0xFF54585F),
    ink3: Color(0xFF878B91),
    line: Color(0xFFE3E5E7),
    line2: Color(0xFFC9CCD0),
    accent: Color(0xFF4DB47C),
    accentSoft: Color(0xFFDFF4E6),
    accentInk: Color(0xFF1F4A33),
    warn: Color(0xFFD68A4D),
    warnSoft: Color(0xFFF7E5D5),
    danger: Color(0xFFC53D2E),
    stage: Color(0xFFEAEBED),
  );

  static const FrequencyColors dark = FrequencyColors(
    bg: Color(0xFF1C1F25),
    surface: Color(0xFF252830),
    surface2: Color(0xFF2D3038),
    surface3: Color(0xFF353941),
    ink: Color(0xFFF1F2F4),
    ink2: Color(0xFFB6B9BE),
    ink3: Color(0xFF878B91),
    line: Color(0xFF3B3F47),
    line2: Color(0xFF4A4F58),
    accent: Color(0xFF5BC58A),
    accentSoft: Color(0xFF2A4A38),
    accentInk: Color(0xFFD9F1E2),
    warn: Color(0xFFE3A26B),
    warnSoft: Color(0xFF4A3A2B),
    danger: Color(0xFFE5604F),
    stage: Color(0xFF15171C),
  );
}

class AppTheme {
  static ThemeData light() => _build(FrequencyColors.light, Brightness.light);
  static ThemeData dark() => _build(FrequencyColors.dark, Brightness.dark);

  static ThemeData _build(FrequencyColors c, Brightness b) {
    final base = b == Brightness.light ? ThemeData.light() : ThemeData.dark();
    return base.copyWith(
      brightness: b,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      dividerColor: c.line,
      colorScheme: ColorScheme(
        brightness: b,
        primary: c.ink,
        onPrimary: c.bg,
        secondary: c.accent,
        onSecondary: c.accentInk,
        error: c.danger,
        onError: Colors.white,
        surface: c.surface,
        onSurface: c.ink,
      ),
      textTheme: _textTheme(c.ink),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: c.ink,
        inactiveTrackColor: c.line,
        thumbColor: c.ink,
        overlayColor: c.ink.withValues(alpha: 0.08),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      extensions: <ThemeExtension<dynamic>>[FrequencyTheme(c)],
    );
  }

  static TextTheme _textTheme(Color ink) {
    return TextTheme(
      displayLarge: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w600,
        fontSize: 28,
        letterSpacing: -0.56,
        height: 1.1,
        color: ink,
      ),
      displayMedium: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w600,
        fontSize: 26,
        letterSpacing: -0.52,
        height: 1.15,
        color: ink,
      ),
      headlineMedium: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w600,
        fontSize: 22,
        letterSpacing: -0.44,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w600,
        fontSize: 16,
        letterSpacing: -0.16,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w600,
        fontSize: 14,
        color: ink,
      ),
      bodyLarge: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w500,
        fontSize: 15,
        color: ink,
      ),
      bodyMedium: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w400,
        fontSize: 14,
        height: 1.5,
        color: ink,
      ),
      bodySmall: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w400,
        fontSize: 12,
        color: ink,
      ),
      labelSmall: TextStyle(
        fontFamily: 'Inter',
        fontWeight: FontWeight.w500,
        fontSize: 11,
        letterSpacing: 0.88,
        color: ink,
      ),
    );
  }
}

/// Theme extension carrying our custom design tokens to widgets.
class FrequencyTheme extends ThemeExtension<FrequencyTheme> {
  final FrequencyColors colors;
  const FrequencyTheme(this.colors);

  static FrequencyTheme of(BuildContext context) =>
      Theme.of(context).extension<FrequencyTheme>()!;

  @override
  FrequencyTheme copyWith({FrequencyColors? colors}) =>
      FrequencyTheme(colors ?? this.colors);

  @override
  FrequencyTheme lerp(ThemeExtension<FrequencyTheme>? other, double t) {
    if (other is! FrequencyTheme) return this;
    return t < 0.5 ? this : other;
  }
}

/// Mono text style (JetBrains Mono fallback to monospace).
const TextStyle kMonoStyle = TextStyle(
  fontFamily: 'JetBrainsMono',
  fontFamilyFallback: ['Courier New', 'monospace'],
  fontFeatures: [FontFeature.tabularFigures()],
);
