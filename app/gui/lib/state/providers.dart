import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/hub_database.dart';
import '../core/db/settings.dart';
import '../core/navigation/app_route.dart';
import '../core/native/hub_native_bindings.dart';
import '../core/util/logger.dart';
import '../core/util/app_paths.dart';

/// 全局数据库实例（异步打开 + 迁移 + FTS5 自检）
final appDatabaseProvider = FutureProvider<HubDatabase>((ref) async {
  HubLogger.instance.init();
  // 原生日志（libs/hub_log）落同一目录：出问题拎一个安装目录包即可复盘
  hubLogInit(HubPaths.logsDir, minLevel: HubLogger.instance.minLevel.value);
  HubLogger.i(
    'app start, dataDir=${HubPaths.dataDir} logDir=${HubPaths.logsDir}',
  );
  hubLogWrite(1, 'app start, logDir=${HubPaths.logsDir}');
  final db = await HubDatabase.open();
  HubLogger.i('database ready, path=${db.path}');
  ref.onDispose(() => db.close());
  return db;
});

/// 设置：整包读写 + 损坏回退默认（《概要设计》§7）
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final dbAsync = ref.watch(appDatabaseProvider);
    return dbAsync.maybeWhen(
      data: (db) => SettingsRepo(db).get(),
      orElse: () => AppSettings.sanitize(null),
    );
  }

  void update(AppSettings next) {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return;
    state = SettingsRepo(db).update(next);
  }

  void patchTheme(ThemeModePref theme) => update(state.copyWith(theme: theme));

  /// 多主题：切换配色预设
  void patchThemePreset(ThemePresetId preset) =>
      update(state.copyWith(themePreset: preset.name));

  /// 自定义主题：明暗 / 主色
  void patchCustomTheme({bool? dark, int? accent}) =>
      update(state.copyWith(customDark: dark, customAccent: accent));

  /// 界面图标风格（auto / outline / filled，见 AppIconStyle）
  void patchIconStyle(AppIconStyle style) =>
      update(state.copyWith(iconStyle: style.name));

  /// 提示音：总开关与音量（0..1）
  void patchSound({bool? enabled, double? volume}) =>
      update(state.copyWith(soundEnabled: enabled, soundVolume: volume));

  void patchRecommend(RecommendSettings s) =>
      update(state.copyWith(recommend: s));
  void patchSearch(SearchSettings s) => update(state.copyWith(search: s));
  void patchNetwork(NetworkSettings s) => update(state.copyWith(network: s));

  /// 本地媒体库：视频扫描目录
  void patchMedia(MediaSettings s) => update(state.copyWith(media: s));

  /// 115 会话：绑定设备槽位 / 云端进度轮询
  void patchPan115(Pan115Settings s) => update(state.copyWith(pan115: s));

  /// 壳层布局整包覆盖（设置页「界面布局」卡用）
  void patchShellLayout(ShellLayoutSettings s) =>
      update(state.copyWith(shellLayout: s));

  /// 壳层布局单字段补丁（保留未传字段）
  void patchShell({
    NavPosition? navPosition,
    bool? showNavLabels,
    StatusBarPosition? statusBarPosition,
    bool? showStatusPage,
    bool? showStatusDbVersion,
    bool? showStatusFts,
    bool? showStatusAppVersion,
  }) => patchShellLayout(
    state.shellLayout.copyWith(
      navPosition: navPosition,
      showNavLabels: showNavLabels,
      statusBarPosition: statusBarPosition,
      showStatusPage: showStatusPage,
      showStatusDbVersion: showStatusDbVersion,
      showStatusFts: showStatusFts,
      showStatusAppVersion: showStatusAppVersion,
    ),
  );
}

final appSettingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

/// 当前选中的导航页
/// 内部维护浏览历史栈：state 是「当前页路由」，对外 API 与 int 时代一致
/// （select / back / canBack / clearHistory），额外提供 back() 以支持
/// 「返回上一级」（缺陷 CJ1-0006）。
class NavIndex extends Notifier<AppRoute> {
  final List<AppRoute> _history = <AppRoute>[];

  /// 初始页取设置里的「启动页」（默认发现）。
  /// 刻意用 read 而非 watch：建立依赖会让「用户在设置里改启动页」立刻把当前页弹走。
  @override
  AppRoute build() {
    final AppSettings s;
    try {
      s = ref.read(appSettingsProvider);
    } catch (_) {
      return StartPage.startPageRoute(null);
    }
    return StartPage.startPageRoute(s.startPage);
  }

  void select(AppRoute r) {
    if (r == state) return;
    _history.add(state);
    if (_history.length > 32) _history.removeAt(0);
    state = r;
  }

  bool get canBack => _history.isNotEmpty;

  /// 返回上一级；无历史时无操作
  void back() {
    if (_history.isEmpty) return;
    state = _history.removeLast();
  }

  /// 清空历史（用于重置）
  void clearHistory() => _history.clear();
}

final navIndexProvider = NotifierProvider<NavIndex, AppRoute>(NavIndex.new);

/// AsyncValue 安全取值（Riverpod 3.x 不再提供 valueOrNull）
extension AsyncDataX<T> on AsyncValue<T> {
  T? get maybeValue => maybeWhen(data: (d) => d, orElse: () => null);
}
