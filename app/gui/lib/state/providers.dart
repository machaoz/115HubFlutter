import 'package:flutter_riverpod/flutter_riverpod.dart';


import '../core/db/hub_database.dart';
import '../core/db/settings.dart';
import '../core/util/logger.dart';
import '../core/util/app_paths.dart';

/// 全局数据库实例（异步打开 + 迁移 + FTS5 自检）
final appDatabaseProvider = FutureProvider<HubDatabase>((ref) async {
  HubLogger.instance.init();
  HubLogger.i('app start, dataDir=${HubPaths.dataDir}');
  final db = await HubDatabase.open();
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
  void patchRecommend(RecommendSettings s) => update(state.copyWith(recommend: s));
  void patchSearch(SearchSettings s) => update(state.copyWith(search: s));
  void patchNetwork(NetworkSettings s) => update(state.copyWith(network: s));
}

final appSettingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// 当前选中的导航页（0 概览 … 5 设置）
/// 内部维护浏览历史栈：state 仍是「当前页索引」，对外 API 不变，
/// 额外提供 back()/canBack 以支持「返回上一级」（缺陷 CJ1-0006）。
class NavIndex extends Notifier<int> {
  final List<int> _history = <int>[];

  @override
  int build() => 0;

  void select(int i) {
    if (i == state) return;
    _history.add(state);
    if (_history.length > 32) _history.removeAt(0);
    state = i;
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

final navIndexProvider = NotifierProvider<NavIndex, int>(NavIndex.new);

/// AsyncValue 安全取值（Riverpod 3.x 不再提供 valueOrNull）
extension AsyncDataX<T> on AsyncValue<T> {
  T? get maybeValue => maybeWhen(data: (d) => d, orElse: () => null);
}
