import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/hub_database.dart';
import '../../core/db/repos.dart';
import '../../sources/source.dart';
import '../../state/providers.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../discover/discover_page.dart' show searchSeedNotifier;
import 'search_orchestrator.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _ctrl = TextEditingController();
  SearchOrchestrator? _orch;
  SearchUpdate? _update;
  bool _running = false;
  String? _error;
  String? _relayHint;
  bool _inputWasChinese = false;

  @override
  void initState() {
    super.initState();
    searchSeedNotifier.addListener(_consumeSeed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeSeed());
  }

  @override
  void dispose() {
    searchSeedNotifier.removeListener(_consumeSeed);
    _ctrl.dispose();
    super.dispose();
  }

  /// 「发现」页海报详情 → 去搜索
  void _consumeSeed() {
    final seed = searchSeedNotifier.value;
    if (seed == null) return;
    searchSeedNotifier.value = null;
    _ctrl.text = seed;
    _start();
  }

  List<SourceLite> _sources() {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return const <SourceLite>[];
    return SourceRepo(db).listAll();
  }

  Future<void> _start() async {
    final raw = _ctrl.text.trim();
    // 错误态：保留用户输入，仅高亮 —— 绝不清空
    if (raw.isEmpty) {
      setState(() => _error = 'empty');
      return;
    }
    setState(() {
      _error = null;
      _running = true;
      _update = null;
      _relayHint = null;
      _inputWasChinese = _looksChinese(raw);
    });
    final db = ref.read(appDatabaseProvider).maybeValue;
    final settings = ref.read(appSettingsProvider);
    final sources = _sources();
    if (sources.isEmpty) {
      setState(() {
        _running = false;
        _error = '没有可用的数据源';
      });
      return;
    }

    // CJ1-0007 中文译名回源：先取原文名，再用原文名检索索引源
    String query = raw;
    if (_inputWasChinese) {
      final original = await _doubanOriginalName(raw, settings.network.proxy);
      if (original != null && original.isNotEmpty && original != raw) {
        query = original;
        if (!mounted) return;
        setState(() => _relayHint = original);
      }
    }

    _orch = SearchOrchestrator(sources: sources, settings: settings);
    final orch = _orch!;

    if (db != null) HistoryRepo(db).add(raw);

    await for (final u in orch.run(query)) {
      if (!mounted) return;
      setState(() => _update = u);
    }
    if (!mounted) return;
    setState(() => _running = false);
  }

  void _stop() {
    _orch?.cancel();
    setState(() => _running = false);
    if (mounted) showHubToast(context, '已取消，迟到批次已丢弃');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final sources = _sources();
    final db = ref.read(appDatabaseProvider).maybeValue;

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        Text('聚合搜索', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('多源并发 · 流式返回 · 可取消 · 去重排序（分桶：磁力/秒传/分享）',
            style: TextStyle(color: t.textDim)),
        const SizedBox(height: 16),
        // 搜索框
        Semantics(
          textField: true,
          label: '搜索关键词',
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _start(),
                  decoration: InputDecoration(
                    hintText: '输入片名 / 导演 / 关键词，回车搜索…',
                    errorText: _error == 'empty' ? '请输入关键词后再搜索' : null,
                    prefixIcon: Icon(Icons.search, size: 20, color: t.textDim),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              AccentButton(
                label: '搜索',
                icon: Icons.search,
                onPressed: _running ? null : _start,
              ),
              const SizedBox(width: 8),
              GhostButton(
                label: '停止',
                icon: Icons.stop,
                onPressed: _running ? _stop : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 源状态
        if (sources.isNotEmpty)
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (final s in sources) _SourceChip(source: s, update: _update),
            ],
          ),
        const SizedBox(height: 18),
        if (_relayHint != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: HubCard(
              child: Text(
                '已按译名回源：$_relayHint 检索',
                style: TextStyle(color: t.cyan),
              ),
            ),
          ),
        if (_error != null && _error != 'empty')
          HubCard(
            child: Text(_error!, style: TextStyle(color: t.danger)),
          ),
        _buildResult(context, t, db),
      ],
    );
  }

  Widget _buildResult(BuildContext context, AppTokens t, HubDatabase? db) {
    if (_running && _update == null) {
      return Column(
        children: List<Widget>.generate(
          5,
          (i) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: HubCard(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SkeletonBox(width: 320 - (i * 22.0), height: 15),
                        const SizedBox(height: 8),
                        const SkeletonBox(width: 180, height: 12),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final u = _update;
    if (u == null) {
      return HubCard(
        dashed: true,
        child: Text(
          '还没有搜索。提示：中文片名在英文索引源通常 0 结果，可试试英文名（如 Oppenheimer）；'
          '也可在「设置 - 源适配器」开启演示源进行离线验证。',
          style: TextStyle(color: t.textDim),
        ),
      );
    }
    if (u.groups.isEmpty) {
      final hint = (u.done && _inputWasChinese && _relayHint == null)
          ? '中文关键词在英文索引源通常无结果，可尝试英文名，或在设置中启用演示源'
          : (u.done ? '没有找到结果。' : '正在检索…');
      return HubCard(
        child: Text(hint, style: TextStyle(color: t.textDim)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: <Widget>[
              Text('共 ${u.groups.length} 条',
                  style: TextStyle(color: t.text, fontWeight: FontWeight.w600)),
              const SizedBox(width: 10),
              if (!u.done)
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 6),
                    Text('流式返回中…', style: TextStyle(color: t.textDim, fontSize: 13)),
                  ],
                ),
            ],
          ),
        ),
        for (final g in u.groups)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ResultRow(
              item: _representative(g),
              groupSize: g.length,
              db: db,
            ),
          ),
      ],
    );
  }

  ResourceItem _representative(List<ResourceItem> g) {
    var best = g.first;
    for (final it in g) {
      if (it.hotness > best.hotness) best = it;
    }
    return best;
  }

  bool _looksChinese(String s) =>
      RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]').hasMatch(s);

  String? _extractLatin(String s) {
    if (s.isEmpty) return null;
    String? best;
    for (final m in RegExp(r"[A-Za-z0-9][A-Za-z0-9'’:\.\- ]*",
            caseSensitive: false)
        .allMatches(s)) {
      final t = m.group(0)!.trim();
      if (t.isNotEmpty && (best == null || t.length > best.length)) best = t;
    }
    return best;
  }

  Future<String?> _doubanOriginalName(String kw, String proxy) async {
    try {
      final d = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        responseType: ResponseType.plain,
      ));
      if (proxy.isNotEmpty) {
        d.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
          final c = HttpClient();
          c.findProxy = (uri) => 'PROXY $proxy';
          return c;
        });
      }
      final res = await d.get<String>(
        'https://movie.douban.com/j/subject_suggest?q=${Uri.encodeQueryComponent(kw)}',
        options: Options(headers: <String, String>{
          'user-agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
          'referer': 'https://movie.douban.com/',
          'accept': 'application/json, text/plain, */*',
        }),
      );
      final data = jsonDecode(res.data ?? '[]');
      if (data is List && data.isNotEmpty) {
        final e = data.first as Map;
        final sub = (e['sub_title'] ?? '').toString();
        final title = (e['title'] ?? '').toString();
        final fromSub = _extractLatin(sub);
        if (fromSub != null && fromSub.isNotEmpty) return fromSub;
        final fromTitle = _extractLatin(title);
        if (fromTitle != null && fromTitle.isNotEmpty) return fromTitle;
      }
    } catch (_) {
      // 取译名失败则回退原文检索
    }
    return null;
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source, required this.update});
  final SourceLite source;
  final SearchUpdate? update;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final st = update?.sources
        .where((s) => s.id == source.id)
        .map((s) => s.state)
        .firstOrNull;
    final (Color c, IconData icon) = switch (st) {
      SourceState.ok => (t.ok, Icons.check_circle),
      SourceState.failed => (t.danger, Icons.error_outline),
      SourceState.running => (t.cyan, Icons.sync),
      SourceState.skipped => (t.warn, Icons.hourglass_empty),
      _ => (t.textDim, Icons.radio_button_unchecked),
    };
    if (!source.enabled) {
      return HubChip(label: '${source.name} · 已停用');
    }
    return HubChip(
      label: '${source.name} · ${source.id.contains("demo") ? "演示" : "真源"}',
      selected: st == SourceState.ok,
      icon: icon,
      color: c,
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.item, required this.groupSize, required this.db});
  final ResourceItem item;
  final int groupSize;
  final HubDatabase? db;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 260, maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: t.textHi, fontWeight: FontWeight.w600, fontSize: 15),
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    if (item.resolution != null) _Tag(item.resolution!, t),
                    if (item.codec != null) _Tag(item.codec!, t),
                    _Tag(db == null ? '' : '', t, size: fmtBytes(item.sizeBytes)),
                    if (item.season != null) _Tag('S${item.season}', t),
                    _Tag(item.sourceId, t),
                    if (groupSize > 1) _Tag('×$groupSize', t),
                  ],
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _ActBtn(
                icon: Icons.copy_all_outlined,
                label: '复制',
                t: t,
                onTap: () {
                  showHubToast(
                      context, '已复制：${item.copyTarget.split('&').first}');
                },
              ),
              const SizedBox(width: 8),
              _ActBtn(
                icon: Icons.star_outline,
                label: '收藏',
                t: t,
                onTap: () {
                  if (db == null) return;
                  try {
                    FavoritesRepo(db!).add(item);
                    showHubToast(context, '已收藏（去重键 ${item.favoriteKey}）');
                  } catch (e) {
                    showHubToast(context, '收藏失败：$e');
                  }
                },
              ),
              const SizedBox(width: 8),
              AccentButton(
                label: '导入',
                icon: Icons.download_for_offline_outlined,
                onPressed: db == null
                    ? null
                    : () {
                        try {
                          ImportRepo(db!).enqueue(
                            kind: item.kind.name,
                            target: item.copyTarget,
                            title: item.title,
                          );
                          showHubToast(context, '已加入导入队列');
                        } catch (e) {
                          showHubToast(context, '入队失败：$e');
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.t, {this.size});
  final String text;
  final AppTokens t;
  final String? size;

  @override
  Widget build(BuildContext context) {
    final label = size ?? text;
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: t.cyan.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: t.cyan, fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ActBtn extends StatelessWidget {
  const _ActBtn({required this.icon, required this.label, required this.t, required this.onTap});
  final IconData icon;
  final String label;
  final AppTokens t;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: t.surface,
              border: Border.all(color: t.border),
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: Tooltip(
              message: label,
              child: Icon(icon, size: 19, color: t.textHi),
            ),
          ),
        ),
      );
}
