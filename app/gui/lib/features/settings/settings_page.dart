import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/hub_database.dart';
import '../../core/db/settings.dart';
import '../../core/util/logger.dart';
import '../../sources/adapters.dart';
import '../../sources/source.dart';
import '../../state/providers.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController _proxy = TextEditingController();
  final TextEditingController _maxResults = TextEditingController();
  final TextEditingController _concurrency = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = ref.read(appSettingsProvider);
      _proxy.text = s.network.proxy;
      _maxResults.text = '${s.search.maxResults}';
      _concurrency.text = '${s.search.concurrency}';
    });
  }

  @override
  void dispose() {
    _proxy.dispose();
    _maxResults.dispose();
    _concurrency.dispose();
    super.dispose();
  }

  void _save() {
    final s = ref.read(appSettingsProvider);
    final ctl = ref.read(appSettingsProvider.notifier);
    ctl.update(s.copyWith(
      network: s.network.copyWith(proxy: _proxy.text.trim()),
      search: SearchSettings(
        maxResults: int.tryParse(_maxResults.text.trim()) ?? s.search.maxResults,
        concurrency: int.tryParse(_concurrency.text.trim()) ?? s.search.concurrency,
        cacheTtlMinutes: s.search.cacheTtlMinutes,
        sinceDays: s.search.sinceDays,
        blacklist: s.search.blacklist,
      ),
    ));
    showHubToast(context, '设置已保存');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    final db = ref.watch(appDatabaseProvider).maybeValue;
    final sources = db == null ? <SourceLite>[] : SourceRepo(db).listAll();

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        Text('设置中心', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 18),

        // 主题
        HubCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('主题', style: TextStyle(color: t.textHi, fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              LayoutBuilder(builder: (context, c) {
                final cols = c.maxWidth > 700 ? 3 : 1;
                final items = <(ThemeModePref, String, String)>[
                  (ThemeModePref.dark, '深色', '石墨极光'),
                  (ThemeModePref.light, '浅色', '冷调纸面'),
                  (ThemeModePref.system, '跟随系统', '零侵入切换'),
                ];
                return GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: cols,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 3.2,
                  children: items.map((it) {
                    final selected = s.theme == it.$1;
                    return HubCard(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      onTap: () => ref
                          .read(appSettingsProvider.notifier)
                          .patchTheme(it.$1),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              if (selected)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Icon(Icons.check_circle, size: 16, color: t.accent),
                                ),
                              Text(it.$2,
                                  style: TextStyle(
                                      color: t.textHi, fontWeight: FontWeight.w700)),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(it.$3, style: TextStyle(color: t.textDim, fontSize: 12.5)),
                        ],
                      ),
                    );
                  }).toList(),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 16),

        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 900;
          final src = _SourcesCard(sources: sources, db: db, t: t);
          final other = Column(children: <Widget>[
            _NetworkCard(
              proxy: _proxy,
              maxResults: _maxResults,
              concurrency: _concurrency,
              onSave: _save,
            ),
            const SizedBox(height: 16),
            _RecommendCard(),
            const SizedBox(height: 16),
            _DataCard(db: db),
          ]);
          if (!wide) {
            return Column(children: <Widget>[src, const SizedBox(height: 16), other]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: src),
              const SizedBox(width: 16),
              Expanded(child: other),
            ],
          );
        }),
        const SizedBox(height: 16),
        _AboutCard(db: db),
      ],
    );
  }
}

class _SourcesCard extends ConsumerStatefulWidget {
  const _SourcesCard({required this.sources, required this.db, required this.t});
  final List<SourceLite> sources;
  final HubDatabase? db;
  final AppTokens t;

  @override
  ConsumerState<_SourcesCard> createState() => _SourcesCardState();
}

class _SourcesCardState extends ConsumerState<_SourcesCard> {
  List<SourceLite> _sources = const <SourceLite>[];
  final Map<String, Health> _health = <String, Health>{};

  @override
  void initState() {
    super.initState();
    _sources = widget.sources;
  }

  @override
  void didUpdateWidget(covariant _SourcesCard old) {
    super.didUpdateWidget(old);
    _sources = widget.sources;
  }

  /// CJ1-0008-a 切换/新增/删除后重新读库并重建 UI
  void _refresh() {
    final db = widget.db;
    if (db == null) return;
    setState(() => _sources = SourceRepo(db).listAll());
  }

  Future<void> _toggle(SourceLite s, bool v) async {
    final db = widget.db;
    if (db == null) return;
    SourceRepo(db).setEnabled(s.id, v);
    _refresh();
  }

  void _deleteCustom(String id) {
    final db = widget.db;
    if (db == null || db.readOnly) {
      showHubToast(context, '数据库只读，无法删除自定义源');
      return;
    }
    db.handle.execute('DELETE FROM source_site WHERE id=?', <Object?>[id]);
    showHubToast(context, '已删除自定义源');
    _refresh();
  }

  void _insertCustom(String name, ResourceKind kind, String addr) {
    final db = widget.db;
    if (db == null || db.readOnly) {
      showHubToast(context, '数据库只读，无法写入自定义源');
      return;
    }
    final id = 'custom-${DateTime.now().millisecondsSinceEpoch}';
    final cfg = kind == ResourceKind.magnet
        ? <String, dynamic>{'custom': true, 'baseUrl': addr}
        : <String, dynamic>{'custom': true, 'shareUrl': addr};
    db.handle.execute(
      'INSERT INTO source_site(id,name,kind,enabled,priority,rate_limit_rps,timeout_ms,health,config_json) '
      'VALUES(?,?,?,?,?,?,?,?,?)',
      <Object?>[
        id,
        name,
        kind.name,
        1,
        50,
        1,
        8000,
        jsonEncode(<String, dynamic>{'ok': true}),
        jsonEncode(cfg),
      ],
    );
    showHubToast(context, '已新增自定义源：$name');
    _refresh();
  }

  void _showAddDialog() {
    final db = widget.db;
    if (db == null || db.readOnly) {
      showHubToast(context, '数据库只读，无法新增自定义源');
      return;
    }
    final nameC = TextEditingController();
    final addrC = TextEditingController();
    var kind = ResourceKind.magnet;
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          backgroundColor: widget.t.surfaceSolid,
          title: Text('新增自定义源', style: TextStyle(color: widget.t.textHi)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(hintText: '名称'),
                ),
                const SizedBox(height: 10),
                HubSegmented<ResourceKind>(
                  label: '类型',
                  items: const <(ResourceKind, String)>[
                    (ResourceKind.magnet, '磁力'),
                    (ResourceKind.pan115, '115 资源'),
                  ],
                  value: kind,
                  onChanged: (v) => setSt(() => kind = v),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: addrC,
                  decoration: InputDecoration(
                    hintText: kind == ResourceKind.magnet
                        ? '磁力 baseUrl，如 https://apibay.org'
                        : '115 资源链接',
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            GhostButton(
              label: '取消',
              onPressed: () => Navigator.of(ctx).pop(),
            ),
            AccentButton(
              label: '保存',
              onPressed: () {
                final name = nameC.text.trim();
                final addr = addrC.text.trim();
                if (name.isEmpty || addr.isEmpty) {
                  showHubToast(context, '名称和地址不能为空');
                  return;
                }
                Navigator.of(ctx).pop();
                _insertCustom(name, kind, addr);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _probe(SourceLite s) async {
    final settings = ref.read(appSettingsProvider);
    try {
      final adapter = adapterFor(s);
      final ctx = AdapterContext(source: s, proxy: settings.network.proxy);
      final check = adapter.healthCheck?.call(ctx);
      Health h;
      if (check != null) {
        h = await check;
      } else {
        // 无显式健康检查 → 用一次真实检索探测（结果条数即健康信号）
        final items = await adapter.search('ubuntu', ctx);
        h = Health(ok: items.isNotEmpty, message: '探测到 ${items.length} 条');
      }
      if (!mounted) return;
      setState(() => _health[s.id] = h);
      if (widget.db case final db?) {
        SourceRepo(db).updateHealth(s.id, h);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _health[s.id] = Health(ok: false, message: '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final canWrite = widget.db != null && !(widget.db!.readOnly);
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text('源适配器',
                    style: TextStyle(color: t.textHi, fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              Text('${_sources.where((e) => e.enabled).length}/${_sources.length} 启用',
                  style: TextStyle(color: t.textDim, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 12),
          if (_sources.isEmpty)
            Text('没有源记录（迁移未完成？）', style: TextStyle(color: t.warn))
          else
            for (final s in _sources)
              _SourceTile(
                source: s,
                t: t,
                health: _health[s.id],
                onProbe: () => _probe(s),
                onToggle: widget.db == null ? null : (v) => _toggle(s, v),
                onDelete: s.id.startsWith('custom-') && canWrite
                    ? () => _deleteCustom(s.id)
                    : null,
              ),
          const SizedBox(height: 12),
          AccentButton(
            label: '+ 新增自定义源',
            icon: Icons.add,
            expand: true,
            onPressed: canWrite ? _showAddDialog : null,
          ),
        ],
      ),
    );
  }
}

class _SourceTile extends ConsumerWidget {
  const _SourceTile({
    required this.source,
    required this.t,
    required this.health,
    required this.onProbe,
    required this.onToggle,
    required this.onDelete,
  });
  final SourceLite source;
  final AppTokens t;
  final Health? health;
  final VoidCallback onProbe;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.bg1,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(source.name,
                    style: TextStyle(color: t.textHi, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    Text('${source.kind.name} · 优先级 ${source.priority}',
                        style: TextStyle(color: t.textDim, fontSize: 12)),
                    if (source.demo)
                      Text('演示源', style: TextStyle(color: t.warn, fontSize: 12)),
                    if (source.id.startsWith('custom-'))
                      Text('自定义', style: TextStyle(color: t.cyan, fontSize: 12)),
                    if (health != null)
                      Text(health!.ok ? '健康' : '异常：${health!.message}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: health!.ok ? t.ok : t.danger, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
          GhostButton(label: '自检', onPressed: onProbe),
          const SizedBox(width: 8),
          if (onDelete != null) ...<Widget>[
            GhostButton(label: '删除', onPressed: onDelete),
            const SizedBox(width: 8),
          ],
          Semantics(
            toggled: source.enabled,
            child: Switch(
              value: source.enabled,
              activeThumbColor: t.accent,
              onChanged: onToggle,
            ),
          ),
        ],
      ),
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.proxy, required this.maxResults, required this.concurrency, required this.onSave});
  final TextEditingController proxy;
  final TextEditingController maxResults;
  final TextEditingController concurrency;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('搜索与网络',
              style: TextStyle(color: t.textHi, fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Semantics(
            textField: true,
            label: '代理地址',
            child: TextField(
              controller: proxy,
              decoration: const InputDecoration(hintText: '代理，如 127.0.0.1:7890（留空直连）'),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: maxResults,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: 'maxResults'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: concurrency,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: '并发数'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AccentButton(label: '保存', icon: Icons.save_outlined, onPressed: onSave),
        ],
      ),
    );
  }
}

class _RecommendCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('首页推荐',
              style: TextStyle(color: t.textHi, fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(child: Text('推荐总开关', style: TextStyle(color: t.text))),
              Switch(
                value: s.recommend.enabled,
                activeThumbColor: t.accent,
                onChanged: (v) => ref
                    .read(appSettingsProvider.notifier)
                    .patchRecommend(s.recommend.copyWith(enabled: v)),
              ),
            ],
          ),
          // 【V1.1.0 预留】首页数据源可切换
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('数据源', style: TextStyle(color: t.text)),
                    Text('V1.1.0 将支持 TMDB / 自定义源',
                        style: TextStyle(color: t.textDim, fontSize: 12)),
                  ],
                ),
              ),
              HubSegmented<String>(
                label: '首页数据源',
                items: const <(String, String)>[('douban', '豆瓣'), ('tmdb', 'TMDB')],
                value: s.recommend.sourceId,
                onChanged: (v) {
                  if (v == 'tmdb') {
                    showHubToast(context, 'TMDB 源将在 V1.1.0 提供（当前仍走豆瓣）');
                    return;
                  }
                  ref.read(appSettingsProvider.notifier).patchRecommend(
                      s.recommend.copyWith(sourceId: v));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DataCard extends ConsumerWidget {
  const _DataCard({required this.db});
  final HubDatabase? db;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('数据与桌面',
              style: TextStyle(color: t.textHi, fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(child: Text('退出自动备份', style: TextStyle(color: t.text))),
              Switch(
                value: s.autoBackup,
                activeThumbColor: t.accent,
                onChanged: (v) => ref
                    .read(appSettingsProvider.notifier)
                    .update(s.copyWith(autoBackup: v)),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(child: Text('关闭到托盘', style: TextStyle(color: t.text))),
              Switch(
                value: s.minimizeToTray,
                activeThumbColor: t.accent,
                onChanged: (v) => ref
                    .read(appSettingsProvider.notifier)
                    .update(s.copyWith(minimizeToTray: v)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AccentButton(
            label: '立即备份（VACUUM INTO 快照）',
            icon: Icons.backup_outlined,
            expand: true,
            onPressed: db == null
                ? null
                : () async {
                    try {
                      final to = await db!.backup();
                      HubLogger.i('备份完成 $to');
                      if (context.mounted) showHubToast(context, '备份完成：$to');
                    } catch (e) {
                      HubLogger.e('备份失败', e);
                      if (context.mounted) showHubToast(context, '备份失败：$e');
                    }
                  },
          ),
        ],
      ),
    );
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard({required this.db});
  final HubDatabase? db;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('关于',
                        style: TextStyle(color: t.textHi, fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      'Magnetic115Hub 1.0.1 · 库 user_version = ${db?.userVersion ?? '-'} · '
                      '与 Electron 版 hub.db 双向可开',
                      style: TextStyle(color: t.textDim, fontSize: 13),
                    ),
                  ],
                ),
              ),
              HubChip(
                label: db?.fts5Available == true ? 'FTS5 可用' : 'FTS5 不可用',
                selected: true,
                color: db?.fts5Available == true ? t.ok : t.warn,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.bg1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.border),
            ),
            child: Text(
              '免责声明：本工具仅索引公开元数据，不下载/缓存/分发任何文件内容；'
              '仅在115网盘内使用，转载/分享请自行确认版权合规。',
              style: TextStyle(color: t.textDim, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}
