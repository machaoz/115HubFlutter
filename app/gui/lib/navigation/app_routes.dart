import 'package:flutter/material.dart';

import '../core/navigation/app_route.dart';
import '../features/overview/overview_page.dart';
import '../features/discover/discover_page.dart';
import '../features/search/search_page.dart';
import '../features/import/import_page.dart';
import '../features/library/library_page.dart';
import '../features/media/media_page.dart';
import '../features/settings/settings_page.dart';

// 路由枚举定义在零依赖的 core 层（core 不反向依赖 flutter），这里转出，
// 调用点只需 `import 'navigation/app_routes.dart'` 即可拿到 AppRoute。
export '../core/navigation/app_route.dart';

/// 页面描述：`kAppPages` 的一行。
///
/// 图标语义沿用原 `NavItem`：[icon] 常态（outlined），[activeIcon] 激活态（filled）。
/// 动效不再按项配置（4.1 起全项统一缩放+淡入，见 app_shell.dart `_NavIcon`）。
class PageDescriptor {
  const PageDescriptor({
    required this.route,
    required this.icon,
    required this.builder,
    this.activeIcon,
  });

  final AppRoute route;

  /// 持久化 id（= 枚举名）
  String get id => route.id;

  /// 导航标签 / 状态栏 / 设置页下拉的唯一来源（来自 AppRouteX.label）
  String get label => route.label;

  final IconData icon;

  /// 激活态图标；未指定时退化为 [icon]
  final IconData? activeIcon;

  /// 页面构造器。由 AppShell 首次构建时调用一次并缓存，
  /// 保证后续重建复用同一实例（IndexedStack 内各页状态不丢）。
  final WidgetBuilder builder;

  /// 是否在导航中露出（来自 `AppRoute.visible`，core 层单一真相源 ——
  /// 这里**不**再存一份，避免 UI 与 core 两处走偏）
  bool get visible => route.visible;
}

/// **页面注册表：顺序即导航顺序**，与 `AppRoute` 枚举声明顺序严格一致。
///
/// 新增页面的全部改动 = 枚举加一个值 + 这里加一行；
/// `app.dart` / `providers.dart` / `app_shell.dart` / `settings.dart` 均无需改动。
final List<PageDescriptor> kAppPages = <PageDescriptor>[
  PageDescriptor(
    route: AppRoute.overview,
    icon: Icons.space_dashboard_outlined,
    activeIcon: Icons.space_dashboard,
    builder: (_) => const OverviewPage(),
  ),
  PageDescriptor(
    route: AppRoute.discover,
    icon: Icons.grid_view_outlined,
    activeIcon: Icons.grid_view,
    builder: (_) => const DiscoverPage(),
  ),
  PageDescriptor(
    route: AppRoute.search,
    icon: Icons.search_outlined,
    activeIcon: Icons.search,
    builder: (_) => const SearchPage(),
  ),
  PageDescriptor(
    route: AppRoute.import,
    icon: Icons.download_for_offline_outlined,
    activeIcon: Icons.download_for_offline,
    builder: (_) => const ImportPage(),
  ),
  PageDescriptor(
    route: AppRoute.library,
    icon: Icons.star_outline,
    activeIcon: Icons.star,
    builder: (_) => const LibraryPage(),
  ),
  PageDescriptor(
    route: AppRoute.settings,
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
    builder: (_) => const SettingsPage(),
  ),
  // 4.0 新增：视频媒体库（本地视频扫描 + 播放，见 features/media/media_page.dart）
  PageDescriptor(
    route: AppRoute.media,
    icon: Icons.video_library_outlined,
    activeIcon: Icons.video_library,
    builder: (_) => const MediaPage(),
  ),
];

/// [pages] 中可见的部分（导航渲染 / IndexedStack 用）
List<PageDescriptor> visiblePagesOf(List<PageDescriptor> pages) =>
    pages.where((p) => p.visible).toList(growable: false);

/// 默认注册表中可见的页面
List<PageDescriptor> get kVisiblePages => visiblePagesOf(kAppPages);

// ---------------------------------------------------------------- 两套下标
//
// 【为什么是两套】全量注册序与可见序不是一回事：隐藏一个页面会让可见序整体前移，
// 而持久化/老数据还原必须与可见性无关、永不漂移。两套**分开命名**，禁止混用。

/// **全量注册序**（= AppRoute 枚举声明顺序）：持久化 route id、老 int 数据还原用。
/// 不随任何页面的可见性变化而漂移。
int registeredIndex(AppRoute route) => route.index;

/// **全量注册序** → 路由；越界回落到 [AppRouteX.defaultStart]
AppRoute registeredRouteAt(int i) => appRouteAt(i);

/// **可见序**：渲染与用户交互（导航栏选中态、IndexedStack 下标）用这一套。
/// [pages] 需为可见列表（见 [visiblePagesOf]）；路由不可见时回落到默认页的位置。
int visibleIndex(AppRoute route, List<PageDescriptor> pages) {
  final i = pages.indexWhere((p) => p.route == route);
  if (i >= 0) return i;
  final d = pages.indexWhere((p) => p.route == AppRouteX.defaultStart);
  return d >= 0 ? d : 0;
}

/// **可见序** → 路由；越界回落到 [AppRouteX.defaultStart]
AppRoute visibleRouteAt(int i, List<PageDescriptor> pages) {
  if (i < 0 || i >= pages.length) return AppRouteX.defaultStart;
  return pages[i].route;
}
