/// 导航路由标识 —— 页面切换的**唯一真相来源**
///
/// 【为什么要有这个文件】
/// 4.0 之前页面切换靠硬编码 int 下标（`NavIndex extends Notifier<int>`、
/// `StartPage` 里写死 `overview→0 … settings→5`）。每加一个页面要
/// 同步改 app.dart / providers / settings / app_shell，漏改就是**静默错位**
/// （点「视频」跳到「导入」），编译器一声不响。改成枚举后，错位在编译期暴露。
///
/// 【为什么放在 core 且零依赖】
/// `core/db/settings.dart` 要校验「启动页 id」是否合法。若枚举定义在 UI 侧，
/// core 就得反向依赖 flutter —— 与本项目 core 层可被纯 Dart 脚本复跑的约定冲突
/// （参见 `core/db/shell_layout.dart`）。因此枚举与标签放这里，纯 Dart；
/// 带图标/页面构造器的描述表在 `lib/navigation/app_routes.dart`。
///
/// 【新增页面的两处登记】
/// 1. 在本枚举加一个值（**位置决定导航顺序**）
/// 2. 在 `lib/navigation/app_routes.dart` 的 `kAppPages` 加一行 —— 顺序必须一致
enum AppRoute {
  overview,
  discover,
  search,
  import,
  library,
  settings,

  /// 4.0 新增：视频媒体库（本地视频扫描 + 播放已落地）
  media,
}

extension AppRouteX on AppRoute {
  /// 持久化用的稳定 id（= 枚举名）。写库只存它，不存下标。
  String get id => name;

  /// 页面中文名（导航标签、状态栏、设置页下拉的唯一来源）
  String get label => switch (this) {
    AppRoute.overview => '概览',
    AppRoute.discover => '发现',
    AppRoute.search => '搜索',
    AppRoute.import => '导入',
    AppRoute.library => '收藏库',
    AppRoute.settings => '设置',
    AppRoute.media => '媒体库',
  };

  /// 是否在导航中露出。`false` = 路由已注册但页面未完工，暂不展示。
  ///
  /// 【为什么放在枚举层而不是页面描述层】可见性是**路由自身的属性**，不是页面
  /// 构造器的属性。它需要被 core 层（启动页候选校验）和 UI 层（导航渲染）同时
  /// 消费 —— 放在 UI 层就逼得 core 交出「全量 + 调用点自己过滤」的隐式契约，
  /// 真相源一分为二。放这里，两边共用同一个 `visible`。
  bool get visible => switch (this) {
    AppRoute.overview => true,
    AppRoute.discover => true,
    AppRoute.search => true,
    AppRoute.import => true,
    AppRoute.library => true,
    AppRoute.settings => true,
    // 媒体库：4.0 的核心功能（High-1 视频播放），**必须对用户可见**。
    //
    // 【别再把它改回 false】曾因「未经真机验证」把它藏起来过，结果是用户拿到
    // 版本后根本找不到播放入口，等于需求没交付。藏起来的风险（100% 没交付）
    // 远大于放出来的风险（未验证，可能有 bug）—— 后者可以靠冒烟快速排除。
    //
    // 当前状态：本地源（扫描目录 + media_kit 播放）已接线完成；网盘源待接入。
    AppRoute.media => true,
  };

  /// 可见路由清单 —— 导航渲染与「启动页」候选的唯一来源
  static List<AppRoute> get visibleValues =>
      AppRoute.values.where((r) => r.visible).toList(growable: false);

  /// 默认启动页
  static const AppRoute defaultStart = AppRoute.discover;

  /// 顺序下标（= 枚举声明顺序 = kAppPages 顺序）
  int get order => index;

  /// 解析任意脏值 → 路由；无法识别返回 null（**永不抛异常**）
  ///
  /// 兼容历史数据：早期版本把启动页存成 int 下标（0 概览 … 5 设置），
  /// 也有存成数字字符串的。这里按「枚举声明顺序」还原，越界回落 null。
  static AppRoute? tryParse(Object? raw) {
    if (raw is AppRoute) return raw;
    if (raw == null) return null;
    if (raw is int) return _routeByOrder(raw);
    final s = raw.toString().trim();
    if (s.isEmpty) return null;
    for (final v in AppRoute.values) {
      if (v.name == s) return v;
    }
    // 老数据：数字（int 或数字字符串）按下标还原
    final n = int.tryParse(s);
    return n == null ? null : _routeByOrder(n);
  }

  /// 解析；无法识别时回落 [fallback]
  static AppRoute parse(Object? raw, AppRoute fallback) =>
      tryParse(raw) ?? fallback;
}

/// 按下标取路由（越界返回 null）
AppRoute? _routeByOrder(int i) =>
    (i >= 0 && i < AppRoute.values.length) ? AppRoute.values[i] : null;

/// 按枚举声明顺序取路由（越界回落到 [AppRouteX.defaultStart]）
AppRoute appRouteAt(int i, {AppRoute fallback = AppRouteX.defaultStart}) =>
    _routeByOrder(i) ?? fallback;
