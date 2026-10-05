import 'package:flutter/material.dart';

import '../core/db/settings.dart';

/// 设计令牌 —— 深/浅双态 + 70-20-10 配色体系。
/// 多主题：由 [ThemePreset] 提供多套配色，运行期由 [AppTokensScope] 下发。
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

  /// 自定义主题：仅替换品牌主色，其余令牌保持基线（保证对比度可读）
  AppTokens withAccent(Color a) => AppTokens(
    bg0: bg0,
    bg1: bg1,
    surface: surface,
    surfaceSolid: surfaceSolid,
    border: border,
    borderStrong: borderStrong,
    textHi: textHi,
    text: text,
    textDim: textDim,
    accent: a,
    accent2: Color.lerp(a, Colors.black, isDark ? 0.18 : 0.22)!,
    cyan: cyan,
    ok: ok,
    warn: warn,
    danger: danger,
    brightness: brightness,
  );

  @override
  bool operator ==(Object other) =>
      other is AppTokens &&
      other.bg0 == bg0 &&
      other.bg1 == bg1 &&
      other.surfaceSolid == surfaceSolid &&
      other.accent == accent &&
      other.accent2 == accent2 &&
      other.textHi == textHi &&
      other.brightness == brightness;

  @override
  int get hashCode =>
      Object.hash(bg0, bg1, surfaceSolid, accent, accent2, textHi, brightness);
}

/// 深色基线（石墨极光）
const AppTokens kTokensGraphite = AppTokens(
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

/// 浅色基线（冷调纸面）
const AppTokens kTokensPaper = AppTokens(
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

/// 兼容别名：既有代码引用的 default dark/light
const AppTokens kDark = kTokensGraphite;
const AppTokens kLight = kTokensPaper;

/// 极夜紫（深色）
const AppTokens kTokensMidnight = AppTokens(
  bg0: Color(0xFF0C0A16),
  bg1: Color(0xFF131024),
  surface: Color(0x0EFFFFFF),
  surfaceSolid: Color(0xFF1A1630),
  border: Color(0x1AFFFFFF),
  borderStrong: Color(0x30FFFFFF),
  textHi: Color(0xFFF3F0FA),
  text: Color(0xFFC9C3DE),
  textDim: Color(0xFF8B84A8),
  accent: Color(0xFFA78BFA),
  accent2: Color(0xFF7C5CFA),
  cyan: Color(0xFF22D3EE),
  ok: Color(0xFF4ADE80),
  warn: Color(0xFFFBBF24),
  danger: Color(0xFFFB7185),
  brightness: Brightness.dark,
);

/// 森野绿（深色）
const AppTokens kTokensForest = AppTokens(
  bg0: Color(0xFF0A1210),
  bg1: Color(0xFF0F1A16),
  surface: Color(0x0EFFFFFF),
  surfaceSolid: Color(0xFF14231D),
  border: Color(0x1AFFFFFF),
  borderStrong: Color(0x30FFFFFF),
  textHi: Color(0xFFEEF6F1),
  text: Color(0xFFC2D4C9),
  textDim: Color(0xFF86A091),
  accent: Color(0xFF34D399),
  accent2: Color(0xFF10B981),
  cyan: Color(0xFF4FD1C5),
  ok: Color(0xFF4ADE80),
  warn: Color(0xFFFBBF24),
  danger: Color(0xFFF87171),
  brightness: Brightness.dark,
);

/// 晨曦米（浅色）
const AppTokens kTokensDawn = AppTokens(
  bg0: Color(0xFFF3EFE7),
  bg1: Color(0xFFFAF7F1),
  surface: Color(0x0A20140A),
  surfaceSolid: Color(0xFFFFFFFF),
  border: Color(0x1A201408),
  borderStrong: Color(0x2E201408),
  textHi: Color(0xFF221C14),
  text: Color(0xFF4A4133),
  textDim: Color(0xFF7C7360),
  accent: Color(0xFFD97706),
  accent2: Color(0xFFB45309),
  cyan: Color(0xFF0E7490),
  ok: Color(0xFF15803D),
  warn: Color(0xFFA16207),
  danger: Color(0xFFDC2626),
  brightness: Brightness.light,
);

/// 海盐蓝（浅色）
const AppTokens kTokensOcean = AppTokens(
  bg0: Color(0xFFE7EEF5),
  bg1: Color(0xFFF2F7FB),
  surface: Color(0x0A0F1B26),
  surfaceSolid: Color(0xFFFFFFFF),
  border: Color(0x1A0F1B26),
  borderStrong: Color(0x2E0F1B26),
  textHi: Color(0xFF0F1B26),
  text: Color(0xFF33475B),
  textDim: Color(0xFF64748B),
  accent: Color(0xFF0EA5E9),
  accent2: Color(0xFF2563EB),
  cyan: Color(0xFF06B6D4),
  ok: Color(0xFF16A34A),
  warn: Color(0xFFD97706),
  danger: Color(0xFFDC2626),
  brightness: Brightness.light,
);

/// 主题预设
class ThemePreset {
  const ThemePreset({
    required this.id,
    required this.name,
    required this.desc,
    required this.tokens,
  });

  final ThemePresetId id;
  final String name;
  final String desc;
  final AppTokens tokens;

  bool get isDark => tokens.isDark;
}

/// 内置预设（不含 system / custom，这两者有专门解析逻辑）
const List<ThemePreset> kThemePresets = <ThemePreset>[
  ThemePreset(
    id: ThemePresetId.graphite,
    name: '石墨极光',
    desc: '深色 · 115 橙',
    tokens: kTokensGraphite,
  ),
  ThemePreset(
    id: ThemePresetId.midnight,
    name: '极夜紫',
    desc: '深色 · 星云紫',
    tokens: kTokensMidnight,
  ),
  ThemePreset(
    id: ThemePresetId.forest,
    name: '森野绿',
    desc: '深色 · 松林绿',
    tokens: kTokensForest,
  ),
  ThemePreset(
    id: ThemePresetId.paper,
    name: '冷调纸面',
    desc: '浅色 · 冷静灰蓝',
    tokens: kTokensPaper,
  ),
  ThemePreset(
    id: ThemePresetId.dawn,
    name: '晨曦米',
    desc: '浅色 · 暖木米',
    tokens: kTokensDawn,
  ),
  ThemePreset(
    id: ThemePresetId.ocean,
    name: '海盐蓝',
    desc: '浅色 · 清澈蓝',
    tokens: kTokensOcean,
  ),
];

ThemePreset? presetById(ThemePresetId id) {
  for (final p in kThemePresets) {
    if (p.id == id) return p;
  }
  return null;
}

/// 解析最终生效令牌。
/// - system：跟随系统明暗，深色用石墨极光 / 浅色用冷调纸面
/// - custom：用户自选明暗 + 主色（其余令牌取基线，保证可读性）
AppTokens resolveTokens({
  required ThemePresetId preset,
  required Brightness platformBrightness,
  bool customDark = true,
  int customAccent = 0xFFFF7A2F,
}) {
  switch (preset) {
    case ThemePresetId.system:
      return platformBrightness == Brightness.dark
          ? kTokensGraphite
          : kTokensPaper;
    case ThemePresetId.custom:
      final base = customDark ? kTokensGraphite : kTokensPaper;
      return base.withAccent(Color(customAccent));
    default:
      return presetById(preset)?.tokens ?? kTokensGraphite;
  }
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
    sliderTheme: SliderThemeData(
      activeTrackColor: t.accent,
      thumbColor: t.accent,
      overlayColor: t.accent.withValues(alpha: 0.16),
      inactiveTrackColor: t.border,
    ),
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

/// 令牌下发：包在 MaterialApp 外层，保证页面与弹窗都能取到当前主题
class AppTokensScope extends InheritedWidget {
  const AppTokensScope({super.key, required this.tokens, required super.child});

  final AppTokens tokens;

  static AppTokens of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppTokensScope>()?.tokens ??
      kDark;

  @override
  bool updateShouldNotify(AppTokensScope oldWidget) =>
      oldWidget.tokens != tokens;
}

extension TokenX on BuildContext {
  AppTokens get t => AppTokensScope.of(this);
}
