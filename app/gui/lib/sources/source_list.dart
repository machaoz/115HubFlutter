import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/hub_database.dart';
import '../core/util/logger.dart';
import '../state/providers.dart';
import 'adapters.dart';
import 'protocols.dart';
import 'source.dart';
import 'source_probe.dart';

/// 源列表 + 源写操作的统一门面。
///
/// 存在的意义（P0-6）：
/// 把原先散在 `_SourcesCardState` 里的 5 段裸 SQL、2 次 `setState` 回读、
/// 网络自检与协议识别，收在一处 —— UI 只负责 `ref.watch` 与按钮回调。
///
/// 额外收益：探针任务现在挂在 provider 上，可被 `ref.onDispose` 统一收敛，
/// 不必再靠 widget 的 `mounted` 判断（ Dio 请求与 SQL 仍会执行完）。
final sourceListProvider =
    NotifierProvider<SourceListController, SourceListState>(
      SourceListController.new,
    );

/// 源列表快照：列表本身 + 自检结果（自检结果不是源的属性，不写库）
class SourceListState {
  const SourceListState({
    this.sources = const <SourceLite>[],
    this.health = const <String, Health>{},
  });

  final List<SourceLite> sources;
  final Map<String, Health> health;

  SourceListState copyWith({
    List<SourceLite>? sources,
    Map<String, Health>? health,
  }) => SourceListState(
    sources: sources ?? this.sources,
    health: health ?? this.health,
  );
}

class SourceListController extends Notifier<SourceListState> {
  /// 已经做过自动协议识别的源 id（每源至多一次，避免重复打扰第三方站点）
  final Set<String> _autoDetectTried = <String>{};

  @override
  SourceListState build() {
    final db = ref.watch(appDatabaseProvider).maybeValue;
    if (db == null) return const SourceListState();
    return SourceListState(sources: SourceRepo(db).listAll());
  }

  HubDatabase? get _db => ref.read(appDatabaseProvider).maybeValue;

  /// 可写性统一判断（原 UI 里重复过 4 次的 `widget.db != null && !readOnly`）
  bool get canWrite {
    final db = _db;
    return db != null && !db.readOnly;
  }

  SourceRepo? get _repo {
    final db = _db;
    return db == null ? null : SourceRepo(db);
  }

  void setEnabled(String id, bool v) {
    _repo?.setEnabled(id, v);
    _reload();
  }

  /// 删除自定义源；返回是否真的删了（UI 据此决定 toast 文案）
  bool deleteCustom(String id) {
    final repo = _repo;
    if (repo == null || !canWrite) return false;
    if (!id.startsWith('custom-')) return false;
    repo.deleteCustom(id);
    _reload();
    return true;
  }

  /// 清理演示源，返回被清理条数（0 = 没什么可清）
  int purgeDemo() {
    final repo = _repo;
    if (repo == null || !canWrite) return 0;
    final n = repo.purgeDemo();
    if (n > 0) _reload();
    return n;
  }

  /// 新增自定义源；返回生成的 id（失败返回 null）
  String? insertCustom({
    required String name,
    required ResourceKind kind,
    required String addr,
  }) {
    final repo = _repo;
    if (repo == null || !canWrite) return null;
    final id = repo.insertCustom(name: name, kind: kind, addr: addr);
    _reload();
    return id;
  }

  /// 网络自检：优先走适配器的健康检查，没实现则用一次真实检索当探针
  Future<Health> probeHealth(SourceLite s) async {
    final adapter = adapterFor(s);
    final ctx = AdapterContext(
      source: s,
      proxy: ref.read(appSettingsProvider).network.proxy,
    );
    try {
      final check = adapter.healthCheck(ctx);
      final Health h;
      if (check != null) {
        h = await check;
      } else {
        final items = await adapter.search('ubuntu', ctx);
        h = Health(ok: items.isNotEmpty, message: '探测到 ${items.length} 条');
      }
      final db = _db;
      if (db != null) SourceRepo(db).updateHealth(s.id, h);
      state = state.copyWith(
        health: <String, Health>{...state.health, s.id: h},
      );
      return h;
    } catch (e) {
      final h = Health(ok: false, message: '$e');
      state = state.copyWith(
        health: <String, Health>{...state.health, s.id: h},
      );
      return h;
    }
  }

  /// 给已有源（重新）识别协议；未命中任何已知协议返回 null
  Future<ProbeResult?> detectProtocol(SourceLite s) async {
    final addr = (s.config['baseUrl'] as String?) ?? '';
    if (addr.isEmpty) return null;
    final result = await _probe(addr, (s.config['apiKey'] as String?) ?? '');
    if (result == null) return null;
    _repo?.setProtocol(
      s.id,
      protocol: result.protocol.id,
      apiBase: result.apiBase,
    );
    _reload();
    return result;
  }

  /// 自愈：历史遗留的自定义源（或被手工清掉 protocol 的源）进入设置页时，
  /// 后台补跑一次协议识别 —— 用户不必手动点「识别」，打开页面即修好。
  Future<void> healPendingProtocols() async {
    final db = _db;
    if (db == null || db.readOnly) return;
    for (final s in List<SourceLite>.from(state.sources)) {
      if (s.kind != ResourceKind.magnet) continue;
      if (s.config['protocol'] != null) continue;
      final addr = (s.config['baseUrl'] as String?) ?? '';
      if (addr.isEmpty) continue;
      if (!_autoDetectTried.add(s.id)) continue;
      HubLogger.i('源 ${s.id} 未登记协议，后台自动识别中…');
      final result = await _probe(addr, (s.config['apiKey'] as String?) ?? '');
      // provider 已被销毁（页面离开 / 不再被监听）：停止后续探测与写库。
      // 这是对原实现（只查 widget.mounted）唯一新增的取消语义。
      if (!ref.mounted) return;
      if (result == null) {
        HubLogger.w('源 ${s.id} 自动识别失败：未命中任何已知协议');
        continue;
      }
      SourceRepo(db).setProtocol(
        s.id,
        protocol: result.protocol.id,
        apiBase: result.apiBase,
      );
      HubLogger.i('源 ${s.id} 自动识别成功 → ${result.protocol.label}');
      _reload();
    }
  }

  Future<ProbeResult?> _probe(String addr, String apiKey) async {
    final prober = SourceProber(
      proxy: ref.read(appSettingsProvider).network.proxy,
      timeoutMs: 12000,
    );
    try {
      return await prober.probe(addr, apiKey: apiKey);
    } catch (e) {
      HubLogger.w('协议识别异常：$e');
      return null;
    }
  }

  void _reload() {
    final db = _db;
    if (db == null) return;
    state = state.copyWith(sources: SourceRepo(db).listAll());
  }
}
