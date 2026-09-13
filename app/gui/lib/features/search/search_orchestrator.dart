import 'dart:async';
import 'dart:isolate';

import '../../core/db/settings.dart';
import '../../core/util/logger.dart';
import '../../sources/adapters.dart';
import '../../sources/source.dart';
import 'search_engine.dart';

/// 源在本次检索中的状态（需求：源状态实时指示）
enum SourceState { pending, running, ok, failed, skipped }

class SourceStatus {
  const SourceStatus({required this.id, required this.name, required this.state, this.message = ''});
  final String id;
  final String name;
  final SourceState state;
  final String message;
}

/// 一次流式更新
class SearchUpdate {
  const SearchUpdate({
    required this.requestId,
    required this.groups,
    required this.sources,
    required this.done,
    this.error,
  });

  final int requestId;

  /// 已去重+排序的分组
  final List<List<ResourceItem>> groups;
  final List<SourceStatus> sources;
  final bool done;
  final String? error;
}

/// 可在后台 Isolate 执行的检索任务（保持可序列化）
class _SearchTask {
  const _SearchTask({
    required this.id,
    required this.name,
    required this.kind,
    required this.priority,
    required this.rateLimitRps,
    required this.timeoutMs,
    required this.config,
    required this.demo,
    required this.enabled,
    required this.keyword,
    required this.proxy,
  });

  final String id;
  final String name;
  final String kind;
  final int priority;
  final double rateLimitRps;
  final int timeoutMs;
  final Map<String, dynamic> config;
  final bool demo;
  final bool enabled;
  final String keyword;
  final String proxy;

  SourceLite toSource() => SourceLite(
        id: id,
        name: name,
        kind: kind == 'pan115' ? ResourceKind.pan115 : ResourceKind.magnet,
        enabled: enabled,
        priority: priority,
        rateLimitRps: rateLimitRps,
        timeoutMs: timeoutMs,
        demo: demo,
        config: config,
      );
}

/// Isolate 入口：必须是顶层函数
Future<List<RawItem>> _runTask(_SearchTask task) async {
  final source = task.toSource();
  final adapter = adapterFor(source);
  return adapter.search(task.keyword, AdapterContext(source: source, proxy: task.proxy));
}

/// 搜索编排器
/// - 多源并发（默认 3 并发）
/// - requestId 令牌：停止/重新搜索后，**迟到批次不再进入 UI**（PoC-4 验收点）
/// - 增量产出：normalize → dedupe → rank
class SearchOrchestrator {
  SearchOrchestrator({required this.sources, required this.settings});

  final List<SourceLite> sources;
  final AppSettings settings;

  int _requestId = 0;
  int get currentRequestId => _requestId;

  /// 取消：自增令牌，正在飞行中的结果因 id 不匹配被丢弃
  int cancel() => ++_requestId;

  Stream<SearchUpdate> run(String keyword) async* {
    final my = ++_requestId;
    final enabled = sources.where((s) => s.enabled).toList();
    final status = <String, SourceStatus>{
      for (final s in enabled)
        s.id: SourceStatus(id: s.id, name: s.name, state: SourceState.pending),
    };

    if (enabled.isEmpty) {
      yield SearchUpdate(
        requestId: my,
        groups: const <List<ResourceItem>>[],
        sources: status.values.toList(),
        done: true,
        error: '没有启用的数据源，请到「设置 - 源适配器」开启至少一个源。',
      );
      return;
    }

    final allItems = <ResourceItem>[];
    final queryTokens =
        keyword.toLowerCase().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toSet();

    final concurrency = settings.search.concurrency.clamp(1, 16);
    var next = 0;
    final pending = <Future<void>>{};

    Future<void> wrap(_SearchTask task) {
      final src = task.toSource();
      return _execute(task)
          .then((List<RawItem> items) {
            if (my != _requestId) return; // 迟到批次丢弃（PoC-4）
            allItems.addAll(items.where(_passesBlacklist).map((r) => normalize(r, src)));
            status[src.id] =
                SourceStatus(id: src.id, name: src.name, state: SourceState.ok);
          })
          // ignore: avoid_types_on_closure_parameters
          .catchError((Object e) {
            if (my != _requestId) return;
            status[src.id] = SourceStatus(
                id: src.id, name: src.name, state: SourceState.failed, message: '$e');
            HubLogger.w('源 ${src.id} 检索失败', e);
          });
    }

    List<List<ResourceItem>> snapshotGroups() {
      var groups = dedupe(allItems);
      groups = rankGroups(groups, queryTokens);
      final limit = settings.search.maxResults;
      if (limit > 0 && groups.length > limit) groups = groups.take(limit).toList();
      return groups;
    }

    while (next < enabled.length || pending.isNotEmpty) {
      if (my != _requestId) return; // 已被取消

      while (pending.length < concurrency && next < enabled.length) {
        final s = enabled[next++];
        status[s.id] =
            SourceStatus(id: s.id, name: s.name, state: SourceState.running);
        final task = _SearchTask(
          id: s.id,
          name: s.name,
          kind: s.kind.name,
          priority: s.priority,
          rateLimitRps: s.rateLimitRps,
          timeoutMs: s.timeoutMs,
          config: s.config,
          demo: s.demo,
          enabled: s.enabled,
          keyword: keyword,
          proxy: settings.network.proxy,
        );
        final f = wrap(task);
        pending.add(f);
        f.whenComplete(() => pending.remove(f));
      }

      if (pending.isEmpty) break;
      await Future.any<Object?>(pending.toList());
      if (my != _requestId) return;

      // 每有一个源返回就重算一次并推送（流式）
      yield SearchUpdate(
        requestId: my,
        groups: snapshotGroups(),
        sources: status.values.toList(),
        done: false,
      );
    }

    if (my != _requestId) return;

    yield SearchUpdate(
      requestId: my,
      groups: snapshotGroups(),
      sources: status.values.toList(),
      done: true,
    );
  }

  bool _passesBlacklist(RawItem r) {
    final bl = settings.search.blacklist;
    if (bl.isEmpty) return true;
    for (final w in bl) {
      if (w.isNotEmpty && r.title.toLowerCase().contains(w.toLowerCase())) return false;
    }
    return true;
  }

  /// 优先走独立 Isolate（真实并发 + UI 不卡顿）；失败则回落本 Isolate。
  Future<List<RawItem>> _execute(_SearchTask task) async {
    try {
      return await Isolate.run(() => _runTask(task));
    } catch (e) {
      HubLogger.w('Isolate 执行失败，回落本 Isolate', e);
      return _runTask(task);
    }
  }
}
