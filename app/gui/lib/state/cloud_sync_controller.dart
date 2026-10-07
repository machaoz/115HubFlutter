import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/repos.dart';
import '../core/network/pan115_cloud.dart';
import 'providers.dart';
import 'session.dart';

/// 云端同步快照：概览页与导入页共用同一份，保证两边看到的永远是一份数据
class CloudSyncState {
  const CloudSyncState({
    this.polling = false,
    this.syncing = false,
    this.lastSyncAt,
    this.note = '',
    this.error,
    this.rows = const <Map<String, Object?>>[],
    this.stats = const <String, int>{
      'pending': 0,
      'running': 0,
      'success': 0,
      'failed': 0,
    },
  });

  /// 轮询 Timer 是否在运行（等价于「当前满足轮询条件且已被拉起」）
  final bool polling;

  /// 单次云端请求进行中（UI 用它显示转圈 / 禁用刷新按钮）
  final bool syncing;

  /// 上一次成功同步云端的时刻
  final DateTime? lastSyncAt;

  /// 最近一次云端同步的人话结论（「云端任务 3 条 · 回填 2 条真实进度」这类）
  final String note;

  /// 最近一次同步的失败原因；成功或从未同步过为 null
  final String? error;

  /// 本地任务快照（已被云端真实进度回填）
  final List<Map<String, Object?>> rows;

  /// 队列四态计数：pending / running / success / failed
  final Map<String, int> stats;

  CloudSyncState copyWith({
    bool? polling,
    bool? syncing,
    DateTime? lastSyncAt,
    String? note,
    String? error,
    List<Map<String, Object?>>? rows,
    Map<String, int>? stats,
    bool clearError = false,
    bool clearLastSyncAt = false,
  }) => CloudSyncState(
    polling: polling ?? this.polling,
    syncing: syncing ?? this.syncing,
    lastSyncAt: clearLastSyncAt ? null : (lastSyncAt ?? this.lastSyncAt),
    note: note ?? this.note,
    error: clearError ? null : (error ?? this.error),
    rows: rows ?? this.rows,
    stats: stats ?? this.stats,
  );
}

/// 全 App 唯一的云端同步循环
///
/// 背景：4.0 之前概览页（[]() -> `features/overview`）与导入页各自持有一个
/// `Timer.periodic` 拉同一份 115 云端任务列表，页面越多 Timer 越多；
/// 且概览页把「根据设置重启定时器」写在了 `build()` 里的 `ref.listen` 中，
/// 每次重建都可能重复注册副作用。
///
/// 收敛之后：
/// * 只有这里持有 Timer，页面一律 `ref.watch(cloudSyncControllerProvider)` 消费；
/// * 「该不该轮询」的判断标准集中在 `_shouldPoll()`：
///   设置项 `pollCloudProgress` 打开 + 115 已登录 + 数据库已就绪；
/// * Timer 生命周期绑死在 provider 生命周期上：
///   provider 被 dispose（`ref.onDispose`）或无监听者（`ref.onCancel`）都取消，
///   重新被监听（`ref.onResume`）时按届时条件决定是否再起。
///
/// API：`start()` / `stop()` / `restart()`，外加手动拉一次的 `syncNow()`
/// 与只刷新本地快照的 `refreshLocal()`。一般情况下页面**不需要**调用 start：
/// 只要有人 watch 本 provider，`build()` 就会把循环拉起来。
class CloudSyncController extends Notifier<CloudSyncState> {
  Timer? _timer;
  int? _runningSeconds;

  /// 云端请求重入保护：网络慢时定时器会继续滴答，不能叠加请求
  bool _busy = false;

  @override
  CloudSyncState build() {
    // Timer 只能活到 provider 结束为止
    ref.onDispose(stop);
    // 页面离开 / 被暂停 → 停表；回来 → 按当时条件恢复，不必页面代劳
    ref.onCancel(stop);
    ref.onResume(() => start());

    // 依赖变了就重新决策。注意这里刻意不用 fireImmediately：
    // build 期间同步改 state 是不允许的，首轮由下面的 microtask 补上。
    ref.listen(appDatabaseProvider, (prev, next) => restart(immediate: true));
    ref.listen(appSettingsProvider, (prev, next) => restart());
    ref.listen(sessionProvider, (prev, next) => restart(immediate: true));

    // 推迟到 build 之后再起循环，让 `build()` 本身保持无副作用
    scheduleMicrotask(() => start(immediate: true));
    return const CloudSyncState();
  }

  /// 「是否该轮询」的唯一判定口径（原概览页 / 导入页两处条件的并集）：
  /// 设置开关打开 + 已登录 + DB 已就绪，三者缺一都不打扰 115 接口。
  bool _shouldPoll() {
    if (!ref.mounted) return false;
    if (ref.read(appDatabaseProvider).maybeValue == null) return false;
    if (!ref.read(appSettingsProvider).pan115.pollCloudProgress) return false;
    return ref.read(sessionProvider).isLoggedIn;
  }

  /// 当前轮询间隔（设置里是 3~120s，这里再兜一层下界防止 0 值忙循环）
  int get _intervalSeconds {
    final s = ref.read(appSettingsProvider).pan115.pollIntervalSeconds;
    return s < 1 ? 1 : s;
  }

  /// 按当前条件校准 Timer：条件满足且未起（或间隔变了）就起，不满足就停。
  ///
  /// 幂等：已经在以相同间隔运行时什么都不做，`restart()` 因此可以被随意调用。
  void _apply({required bool immediate}) {
    if (!ref.mounted || !_shouldPoll()) {
      // 【别删这行 refreshLocal】不满足轮询条件（未登录 / 关掉开关 / DB 未就绪）
      // 时也要刷新本地快照：概览页「导入成功」与导入页看板都只读这份快照，
      // 少了它，未登录冷启动会恒为 0 / 空白（用户会以为入队失败而重复点）。
      // refreshLocal() 只写 state、不触发 _apply，无循环调用。
      stop();
      refreshLocal();
      return;
    }
    final seconds = _intervalSeconds;
    if (_timer != null && _runningSeconds == seconds) {
      if (immediate) unawaited(syncNow());
      return;
    }
    _timer?.cancel();
    _runningSeconds = seconds;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) {
      unawaited(syncNow());
    });
    if (!state.polling) state = state.copyWith(polling: true);
    if (immediate) unawaited(syncNow());
  }

  /// 拉起轮询（条件不满足时等价于 stop）。[immediate] 为真时立刻同步一次。
  void start({bool immediate = false}) => _apply(immediate: immediate);

  /// 停掉 Timer。任何时候调用都是安全的，重复调用无副作用。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _runningSeconds = null;
    // onDispose 期间 ref 已不可用，此时只允许清资源、不再写 state
    if (ref.mounted && state.polling) state = state.copyWith(polling: false);
  }

  /// 按当前条件重算一次（设置/会话/DB 变化时内部会自动调用）。
  void restart({bool immediate = false}) => _apply(immediate: immediate);

  /// 只重读本地队列快照：本地增删改任务之后用，不产生网络请求。
  void refreshLocal() {
    if (!ref.mounted) return;
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return;
    final repo = ImportRepo(db);
    state = state.copyWith(rows: repo.list(), stats: repo.stats());
  }

  /// 拉一次 115 云端任务列表，把**真实进度**回填到本地再看一遍队列。
  ///
  /// 未登录时不发请求，只刷新本地快照并如实说明；已登录则无条件执行
  /// （手动点「刷新」不受轮询开关限制）。
  Future<void> syncNow() async {
    if (!ref.mounted) return;
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return;

    refreshLocal();
    final session = ref.read(sessionProvider);
    if (!session.isLoggedIn) {
      state = state.copyWith(
        note: '未登录 115：仅显示本地队列状态',
        syncing: false,
        clearError: true,
      );
      return;
    }
    if (_busy) return;

    _busy = true;
    state = state.copyWith(syncing: true, clearError: true);
    try {
      final settings = ref.read(appSettingsProvider);
      final note = await syncCloudToRepo(
        ImportRepo(db),
        cookie: session.cookie,
        proxy: settings.network.proxy,
        timeoutMs: settings.network.timeoutMs,
      );
      if (!ref.mounted) return;
      final repo = ImportRepo(db);
      state = state.copyWith(
        rows: repo.list(),
        stats: repo.stats(),
        note: note,
        syncing: false,
        lastSyncAt: DateTime.now(),
        clearError: true,
      );
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(syncing: false, error: '云端同步失败：$e');
    } finally {
      _busy = false;
    }
  }
}

final cloudSyncControllerProvider =
    NotifierProvider<CloudSyncController, CloudSyncState>(
      CloudSyncController.new,
    );
