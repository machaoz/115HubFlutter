import 'package:flutter/material.dart';

import '../core/db/settings.dart';

/// 正文字体族偏好。
///
/// 4.0 起随包内置 HarmonyOS Sans SC（见 pubspec.yaml 的 `flutter: fonts:`），
/// 默认使用它；用户可在设置里切回 Windows 系统默认字体。
/// 完整设置 UI 属于「设置页」工作流，这里只提供开关位与解析逻辑。
enum AppFontFamily {
  /// 跟随系统默认（不指定 fontFamily，交给平台/Skia 回退链）
  system,

  /// HarmonyOS Sans SC（简体中文覆盖，含 GBK 全集）
  harmonyOS;

  /// 解析为 Material `ThemeData.fontFamily` 需要的值（null = 跟随系统）
  String? get familyName => switch (this) {
    AppFontFamily.system => null,
    AppFontFamily.harmonyOS => kHarmonyFontFamily,
  };

  static AppFontFamily parse(
    String? raw, [
    AppFontFamily fallback = AppFontFamily.harmonyOS,
  ]) {
    for (final v in AppFontFamily.values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }
}

/// pubspec.yaml 中声明的正文字体 family 名
const String kHarmonyFontFamily = 'HarmonyOS';

/// 设置项 key（写入 AppSettings.general.fontFamily）
const String kFontFamilySettingKey = 'fontFamily';

/// 设计令牌 —— 深/浅双态 + 70-20-10 配色体系。
/// 多主题：由 [ThemePreset] 提供多套配色，运行期由 [AppTokensScope] 下发。
class AppTokens {
  const AppTokens({
    required this.bg0,
    required this.bg1,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.border,
    required this.borderStrong,
    required this.borderSubtle,
    required this.borderDisabled,
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
    this.fontFamily = AppFontFamily.harmonyOS,
  });

  final Color bg0;
  final Color bg1;

  /// 层级底色：**卡片底 = surface1 / hover 态 = surface2 / 浮层 = surface3**
  ///
  /// 这三个取代了旧的半透明 `surface`（UI 规范 §3.9 已弃用：叠在渐变换底色上
  /// 不可控）。旧字段已彻底删除 —— 它与 surface1/2/3 并存时，四个相近的名字
  /// 会让后来者不知道该用哪一个。
  final Color surface1;
  final Color surface2;
  final Color surface3;

  final Color border;
  final Color borderStrong;

  /// 极弱分隔线（同组内的细分隔）
  final Color borderSubtle;

  /// 禁用态描边（与 [textDisabled] 配套）
  final Color borderDisabled;

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

  /// 正文字体族偏好。**真源在这里**，不要再从别处读
  /// （`AppTokensScope` 只是透传）。
  final AppFontFamily fontFamily;

  bool get isDark => brightness == Brightness.dark;

  /// 禁用态文字：由 [textDim] 派生，6 套预设自动一致。
  ///
  /// 刻意做成 getter 而不是字段 —— 做成字段就要在 6 套预设里各录一遍，早晚漏配。
  Color get textDisabled => textDim.withValues(alpha: 0.38);

  /// 聚焦描边：取主色，同上，派生而非新增字段。
  Color get borderFocus => accent;

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
  ///
  /// 走 [copyWith] 而不是手抄字段，避免以后新增令牌时漏抄（历史上漏过）。
  AppTokens withAccent(Color a) => copyWith(
    accent: a,
    accent2: Color.lerp(a, Colors.black, isDark ? 0.18 : 0.22)!,
  );

  AppTokens copyWith({
    Color? bg0,
    Color? bg1,
    Color? surface1,
    Color? surface2,
    Color? surface3,
    Color? border,
    Color? borderStrong,
    Color? borderSubtle,
    Color? borderDisabled,
    Color? textHi,
    Color? text,
    Color? textDim,
    Color? accent,
    Color? accent2,
    Color? cyan,
    Color? ok,
    Color? warn,
    Color? danger,
    Brightness? brightness,
    AppFontFamily? fontFamily,
  }) => AppTokens(
    bg0: bg0 ?? this.bg0,
    bg1: bg1 ?? this.bg1,
    surface1: surface1 ?? this.surface1,
    surface2: surface2 ?? this.surface2,
    surface3: surface3 ?? this.surface3,
    border: border ?? this.border,
    borderStrong: borderStrong ?? this.borderStrong,
    borderSubtle: borderSubtle ?? this.borderSubtle,
    borderDisabled: borderDisabled ?? this.borderDisabled,
    textHi: textHi ?? this.textHi,
    text: text ?? this.text,
    textDim: textDim ?? this.textDim,
    accent: accent ?? this.accent,
    accent2: accent2 ?? this.accent2,
    cyan: cyan ?? this.cyan,
    ok: ok ?? this.ok,
    warn: warn ?? this.warn,
    danger: danger ?? this.danger,
    brightness: brightness ?? this.brightness,
    fontFamily: fontFamily ?? this.fontFamily,
  );

  /// 【`==` 的收录标准】字段是否**影响渲染结果** —— 影响渲染的一律进
  /// （改了就该重建），不影响渲染的可不进，但**必须在该字段上写明原因**，
  /// 否则后人会以为漏了。
  ///
  /// 已知例外：`soundSet`（4.0 待加，见 docs §5.3）只影响发声、不影响 widget 树，
  /// 因此不进 `==`；它落地时请按本规则在字段注释里写明「为何不进」。
  ///
  /// 【守约机制】`test/theme_tokens_test.dart` 有一条**源码文本扫描**断言：
  /// 本类声明的每个字段都必须出现在 `operator ==` 表达式里。
  /// 加字段忘了补 `==` 会立刻红。
  @override
  bool operator ==(Object other) =>
      other is AppTokens &&
      other.bg0 == bg0 &&
      other.bg1 == bg1 &&
      other.surface1 == surface1 &&
      other.surface2 == surface2 &&
      other.surface3 == surface3 &&
      other.border == border &&
      other.borderStrong == borderStrong &&
      other.borderSubtle == borderSubtle &&
      other.borderDisabled == borderDisabled &&
      other.textHi == textHi &&
      other.text == text &&
      other.textDim == textDim &&
      other.accent == accent &&
      other.accent2 == accent2 &&
      other.cyan == cyan &&
      other.ok == ok &&
      other.warn == warn &&
      other.danger == danger &&
      other.brightness == brightness &&
      other.fontFamily == fontFamily;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    bg0,
    bg1,
    surface1,
    surface2,
    surface3,
    border,
    borderStrong,
    borderSubtle,
    borderDisabled,
    textHi,
    text,
    textDim,
    accent,
    accent2,
    cyan,
    ok,
    warn,
    danger,
    brightness,
    fontFamily,
  ]);
}

/// 深色基线（石墨极光）
const AppTokens kTokensGraphite = AppTokens(
  bg0: Color(0xFF0B0E14),
  bg1: Color(0xFF11151F),
  surface1: Color(0xFF161B27),
  surface2: Color(0xFF1C2230),
  surface3: Color(0xFF232A3A),
  border: Color(0x14FFFFFF),
  borderStrong: Color(0x29FFFFFF),
  borderSubtle: Color(0x0FFFFFFF),
  borderDisabled: Color(0x0CFFFFFF),
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
  surface1: Color(0xFFF8FAFD),
  surface2: Color(0xFFEDF1F7),
  surface3: Color(0xFFE3E9F1),
  border: Color(0x1A14181F),
  borderStrong: Color(0x2E14181F),
  borderSubtle: Color(0x0F14181F),
  borderDisabled: Color(0x0C14181F),
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
  surface1: Color(0xFF1A1630),
  surface2: Color(0xFF201D39),
  surface3: Color(0xFF272543),
  border: Color(0x1AFFFFFF),
  borderStrong: Color(0x30FFFFFF),
  borderSubtle: Color(0x0FFFFFFF),
  borderDisabled: Color(0x0CFFFFFF),
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
  surface1: Color(0xFF14231D),
  surface2: Color(0xFF1A2A26),
  surface3: Color(0xFF213230),
  border: Color(0x1AFFFFFF),
  borderStrong: Color(0x30FFFFFF),
  borderSubtle: Color(0x0FFFFFFF),
  borderDisabled: Color(0x0CFFFFFF),
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
  surface1: Color(0xFFFFFFFF),
  surface2: Color(0xFFF5F1E9),
  surface3: Color(0xFFEDE7DC),
  border: Color(0x1A201408),
  borderStrong: Color(0x2E201408),
  borderSubtle: Color(0x0F201408),
  borderDisabled: Color(0x0C201408),
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
  surface1: Color(0xFFFFFFFF),
  surface2: Color(0xFFEDF3F9),
  surface3: Color(0xFFE2ECF5),
  border: Color(0x1A0F1B26),
  borderStrong: Color(0x2E0F1B26),
  borderSubtle: Color(0x0F0F1B26),
  borderDisabled: Color(0x0C0F1B26),
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
  AppFontFamily fontFamily = AppFontFamily.harmonyOS,
}) {
  final AppTokens base = switch (preset) {
    ThemePresetId.system =>
      platformBrightness == Brightness.dark ? kTokensGraphite : kTokensPaper,
    ThemePresetId.custom =>
      (customDark ? kTokensGraphite : kTokensPaper).withAccent(
        Color(customAccent),
      ),
    _ => presetById(preset)?.tokens ?? kTokensGraphite,
  };
  // 字体族是令牌的一部分：不在这里落进去就会出现「设置里切了字体 UI 不变」
  return base.fontFamily == fontFamily
      ? base
      : base.copyWith(fontFamily: fontFamily);
}

/// 应用级 ThemeData —— 正文 16px 起、行高 1.6；标题 ≥2× 字号跳跃
///
/// 字体族**只从 [AppTokens.fontFamily] 取**（`AppFontFamily.system` 的
/// familyName 为 null，表示跟随系统默认字体），不再另开入参 —— 开入参就等于
/// 又给了它一个真源，改字体不重建的老毛病会复发。
ThemeData buildTheme(AppTokens t) {
  final fontFamily = t.fontFamily;
  final base = ThemeData(
    useMaterial3: true,
    brightness: t.brightness,
    scaffoldBackgroundColor: t.bg0,
    splashFactory: InkSparkle.splashFactory,
    fontFamily: fontFamily.familyName,
  );
  return base.copyWith(
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.accent,
      brightness: t.brightness,
      surface: t.surface1,
    ),
    // 显式给到每次 copyWith 后的 TextStyle —— Material 3 的 textTheme 会重建
    // 部分样式，不显式带上 fontFamily 会导致个别角色回退到默认字体
    textTheme: base.textTheme.copyWith(
      bodyMedium: TextStyle(
        fontSize: 16,
        height: 1.6,
        color: t.text,
        fontWeight: FontWeight.w400,
        fontFamily: fontFamily.familyName,
      ),
      bodySmall: TextStyle(
        fontSize: 13.5,
        height: 1.55,
        color: t.textDim,
        fontFamily: fontFamily.familyName,
      ),
      titleLarge: TextStyle(
        fontSize: 28,
        height: 1.25,
        fontWeight: FontWeight.w700,
        color: t.textHi,
        fontFamily: fontFamily.familyName,
      ),
      titleMedium: TextStyle(
        fontSize: 18,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: t.textHi,
        fontFamily: fontFamily.familyName,
      ),
      labelLarge: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: t.textHi,
        fontFamily: fontFamily.familyName,
      ),
      headlineSmall: TextStyle(
        fontSize: 34,
        height: 1.18,
        fontWeight: FontWeight.w800,
        color: t.textHi,
        fontFamily: fontFamily.familyName,
      ),
    ),
    dividerColor: t.border,
    cardColor: t.surface1,
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
        color: t.surface1,
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

  /// 当前生效的正文字体族（设置页切回系统默认时变为 [AppFontFamily.system]）
  ///
  /// **透传**：真源是 `AppTokens.fontFamily`。这里刻意不存第二份 ——
  /// 存了就会变成「设置里改了字体、UI 没重建」的双数据源 bug。
  AppFontFamily get fontFamily => tokens.fontFamily;

  static AppTokens of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppTokensScope>()?.tokens ??
      kDark;

  /// 取当前生效的字体族；无祖先时回落包内默认（HarmonyOS Sans）
  static AppFontFamily fontOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppTokensScope>()
          ?.tokens
          .fontFamily ??
      AppFontFamily.harmonyOS;

  @override
  bool updateShouldNotify(AppTokensScope oldWidget) =>
      oldWidget.tokens != tokens;
}

extension TokenX on BuildContext {
  AppTokens get t => AppTokensScope.of(this);

  /// 当前生效的正文字体族
  AppFontFamily get fontFamily => AppTokensScope.fontOf(this);
}
