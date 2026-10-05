/// 壳层布局设置（导航栏 / 状态栏位置与内容）—— **零依赖纯 Dart**。
///
/// 【为什么单独成文件】本项目的核心逻辑一律落在「零 IO / 零依赖纯函数层」，
/// 以便在 `flutter_tester` 不可用的环境里用 `dart run .tools/*_check.dart`
/// 等价验证（与 `core/network/qr_status.dart` 同一模式）。
/// 如果把这些类型留在 `settings.dart`（它 import 了 hub_database → flutter/services），
/// 纯 Dart 脚本就无法复跑其断言。
library;

/// 导航栏位置（auto = 响应式：窄屏自动落底栏）
enum NavPosition { auto, left, right, bottom }

extension NavPositionX on NavPosition {
  String get id => name;

  /// 未知值一律回落 [fallback]（脏设置绝不崩 UI）
  static NavPosition parse(
    String? raw, [
    NavPosition fallback = NavPosition.auto,
  ]) {
    for (final v in NavPosition.values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }
}

/// 状态栏位置（hidden = 不渲染状态栏）
enum StatusBarPosition { top, bottom, hidden }

extension StatusBarPositionX on StatusBarPosition {
  String get id => name;

  static StatusBarPosition parse(
    String? raw, [
    StatusBarPosition fallback = StatusBarPosition.bottom,
  ]) {
    for (final v in StatusBarPosition.values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }
}

/// 壳层布局设置：导航位置 / 导航标签 / 状态栏位置与内容开关
///
/// 【向后兼容】旧库 JSON 没有 `shell` 段时全部取默认值；出现未知枚举字符串或
/// 非布尔脏值一律回落默认 —— 与全局约定一致：设置损坏只回落，不崩溃。
class ShellLayoutSettings {
  const ShellLayoutSettings({
    this.navPosition = NavPosition.auto,
    this.showNavLabels = true,
    this.statusBarPosition = StatusBarPosition.bottom,
    this.showStatusPage = true,
    this.showStatusDbVersion = true,
    this.showStatusFts = true,
    this.showStatusAppVersion = true,
  });

  /// 导航栏位置：auto 按窗口宽度自动选左栏/底栏
  final NavPosition navPosition;

  /// 导航是否显示文字标签（关闭 → 图标模式，更省横向空间）
  final bool showNavLabels;

  /// 状态栏位置
  final StatusBarPosition statusBarPosition;

  /// 状态栏内容：当前页面 / 数据库版本 / FTS 状态 / 应用版本（各自独立开关）
  final bool showStatusPage;
  final bool showStatusDbVersion;
  final bool showStatusFts;
  final bool showStatusAppVersion;

  /// 四项内容全关时不必渲染空状态栏
  bool get hasStatusContent =>
      showStatusPage ||
      showStatusDbVersion ||
      showStatusFts ||
      showStatusAppVersion;

  ShellLayoutSettings copyWith({
    NavPosition? navPosition,
    bool? showNavLabels,
    StatusBarPosition? statusBarPosition,
    bool? showStatusPage,
    bool? showStatusDbVersion,
    bool? showStatusFts,
    bool? showStatusAppVersion,
  }) => ShellLayoutSettings(
    navPosition: navPosition ?? this.navPosition,
    showNavLabels: showNavLabels ?? this.showNavLabels,
    statusBarPosition: statusBarPosition ?? this.statusBarPosition,
    showStatusPage: showStatusPage ?? this.showStatusPage,
    showStatusDbVersion: showStatusDbVersion ?? this.showStatusDbVersion,
    showStatusFts: showStatusFts ?? this.showStatusFts,
    showStatusAppVersion: showStatusAppVersion ?? this.showStatusAppVersion,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'navPosition': navPosition.name,
    'showNavLabels': showNavLabels,
    'statusBarPosition': statusBarPosition.name,
    'showStatusPage': showStatusPage,
    'showStatusDbVersion': showStatusDbVersion,
    'showStatusFts': showStatusFts,
    'showStatusAppVersion': showStatusAppVersion,
  };

  /// 从任意 JSON 值解析：非 Map / 缺字段 / 脏值全部安全回落
  ///
  /// 【红线】非布尔脏值（`'yes'` / `0` / Map）**必须回落默认而不是抛异常** ——
  /// 抛异常会被 `SettingsRepo.get()` 的兜底捕获，导致整包设置被重置为默认，
  /// 用户的其他配置会被"静默清空"。这类脏值在手工改过 settings_json 的机器上真实存在。
  static ShellLayoutSettings from(Object? raw) {
    final m = raw is Map ? raw : const <String, dynamic>{};
    return ShellLayoutSettings(
      navPosition: NavPositionX.parse(m['navPosition']?.toString()),
      showNavLabels: _asBool(m['showNavLabels'], true),
      statusBarPosition: StatusBarPositionX.parse(
        m['statusBarPosition']?.toString(),
      ),
      showStatusPage: _asBool(m['showStatusPage'], true),
      showStatusDbVersion: _asBool(m['showStatusDbVersion'], true),
      showStatusFts: _asBool(m['showStatusFts'], true),
      showStatusAppVersion: _asBool(m['showStatusAppVersion'], true),
    );
  }

  /// 宽松布尔：只有真正的 `bool` 才采信，其余（含 null）一律回落 [fallback]
  static bool _asBool(Object? v, bool fallback) => v is bool ? v : fallback;

  @override
  bool operator ==(Object other) =>
      other is ShellLayoutSettings &&
      other.navPosition == navPosition &&
      other.showNavLabels == showNavLabels &&
      other.statusBarPosition == statusBarPosition &&
      other.showStatusPage == showStatusPage &&
      other.showStatusDbVersion == showStatusDbVersion &&
      other.showStatusFts == showStatusFts &&
      other.showStatusAppVersion == showStatusAppVersion;

  @override
  int get hashCode => Object.hash(
    navPosition,
    showNavLabels,
    statusBarPosition,
    showStatusPage,
    showStatusDbVersion,
    showStatusFts,
    showStatusAppVersion,
  );
}
