import 'package:flutter/material.dart';

/// 设计令牌 —— 与《UI 设计方案》v1.0 严格一致（深/浅双态 + 70-20-10）
/// 深色：深石墨 70% + 石板面板 20% + 115 橙/数据青 10%
class AppTokens {
  const AppTokens({
    required this.bg0,
    required this.bg1,
    required this.surface,
    required this.surfaceSolid,
    required this.border,
    required this.borderStrong,
    required this.textHi,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.accent2,
    required this.cyan,
    required this.ok,
    required this.warn,
    required this.danger,
    required this.brightness,
  });

  final Color bg0;
  final Color bg1;
  final Color surface;
  final Color surfaceSolid;
  final Color border;
  final Color borderStrong;
  final Color textHi;
  final Color text;
  final Color textDim;
  final Color accent;
  final Color accent2;
  final Color cyan;
  final Color ok;
  final Color warn;
  final Color danger;
  final Brightness brightness;

  bool get isDark => brightness == Brightness.dark;

  /// 记忆点：背景纵深（极光渐变素材）
  LinearGradient get aurora => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          accent.withValues(alpha: isDark ? 0.16 : 0.11),
          cyan.withValues(alpha: isDark ? 0.11 : 0.09),
          bg0,
        ],
      );

  static const AppTokens dark = AppTokens(
    bg0: Color(0xFF0B0E14),
    bg1: Color(0xFF11151F),
    surface: Color(0x0AFFFFFF),
    surfaceSolid: Color(0xFF161B27),
    border: Color(0x14FFFFFF),
    borderStrong: Color(0x29FFFFFF),
    textHi: Color(0xFFF2F4F8),
    text: Color(0xFFC7CEDB),
    textDim: Color(0xFF8A93A6),
    accent: Color(0xFFFF7A2F),
    accent2: Color(0xFFFF5E3A),
    cyan: Color(0xFF34E3D0),
    ok: Color(0xFF4ADE80),
    warn: Color(0xFFFFC15E),
    danger: Color(0xFFFF6B7A),
    brightness: Brightness.dark,
  );

  static const AppTokens light = AppTokens(
    bg0: Color(0xFFE8ECF3),
    bg1: Color(0xFFF1F4F9),
    surface: Color(0x08202431),
    surfaceSolid: Color(0xFFF8FAFD),
    border: Color(0x1A14181F),
    borderStrong: Color(0x2E14181F),
    textHi: Color(0xFF14181F),
    text: Color(0xFF2C333F),
    textDim: Color(0xFF5C6675),
    accent: Color(0xFFF2680F),
    accent2: Color(0xFFE8542A),
    cyan: Color(0xFF0FA89A),
    ok: Color(0xFF1E9E5A),
    warn: Color(0xFFB5791B),
    danger: Color(0xFFD63A4D),
    brightness: Brightness.light,
  );
}

/// 应用级 ThemeData —— 正文 16px 起、行高 1.6；标题 ≥2× 字号跳跃
ThemeData buildTheme(AppTokens t) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: t.brightness,
    scaffoldBackgroundColor: t.bg0,
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.accent,
      brightness: t.brightness,
      surface: t.surfaceSolid,
    ),
    textTheme: base.textTheme.copyWith(
      bodyMedium: TextStyle(
        fontSize: 16,
        height: 1.6,
        color: t.text,
        fontWeight: FontWeight.w400,
      ),
      bodySmall: TextStyle(fontSize: 13.5, height: 1.55, color: t.textDim),
      titleLarge: TextStyle(
        fontSize: 28,
        height: 1.25,
        fontWeight: FontWeight.w700,
        color: t.textHi,
      ),
      titleMedium: TextStyle(
        fontSize: 18,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: t.textHi,
      ),
      labelLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: t.textHi,
      ),
      headlineSmall: TextStyle(
        fontSize: 34,
        height: 1.18,
        fontWeight: FontWeight.w800,
        color: t.textHi,
      ),
    ),
    dividerColor: t.border,
    cardColor: t.surfaceSolid,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.bg1,
      hintStyle: TextStyle(color: t.textDim),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.accent, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.danger),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: t.surfaceSolid,
        border: Border.all(color: t.borderStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: t.text, fontSize: 13),
    ),
  );
}

extension TokenX on BuildContext {
  AppTokens get t =>
      Theme.of(this).brightness == Brightness.dark ? AppTokens.dark : AppTokens.light;
}
