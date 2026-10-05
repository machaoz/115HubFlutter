import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/hub_database.dart';
import '../../core/db/settings.dart';
import '../../core/util/logger.dart';
import '../../core/util/version.dart';
import '../../sources/adapters.dart';
import '../../sources/protocols.dart';
import '../../sources/source.dart';
import '../../sources/source_probe.dart';
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
    ctl.update(
      s.copyWith(
        network: s.network.copyWith(proxy: _proxy.text.trim()),
        search: SearchSettings(
          maxResults:
              int.tryParse(_maxResults.text.trim()) ?? s.search.maxResults,
          concurrency:
              int.tryParse(_concurrency.text.trim()) ?? s.search.concurrency,
          cacheTtlMinutes: s.search.cacheTtlMinutes,
          sinceDays: s.search.sinceDays,
          blacklist: s.search.blacklist,
        ),
      ),
    );
    showHubToast(context, '设置已保存');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final db = ref.watch(appDatabaseProvider).maybeValue;
    final sources = db == null ? <SourceLite>[] : SourceRepo(db).listAll();

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        Text('设置中心', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 18),

        // 主题（先选模式：预设 / 自定义，再展开细节）
        const _ThemeCard(),
        const SizedBox(height: 16),

        // 界面布局（导航位置 / 状态栏，即时生效）
        const _ShellLayoutCard(),
        const SizedBox(height: 16),

        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 900;
            final src = _SourcesCard(sources: sources, db: db, t: t);
            final other = Column(
              children: <Widget>[
                _NetworkCard(
                  proxy: _proxy,
                  maxResults: _maxResults,
                  concurrency: _concurrency,
                  onSave: _save,
                ),
                const SizedBox(height: 16),
                const _Pan115Card(),
                const SizedBox(height: 16),
                _RecommendCard(),
                const SizedBox(height: 16),
                _DataCard(db: db),
              ],
            );
            if (!wide) {
              return Column(
                children: <Widget>[src, const SizedBox(height: 16), other],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: src),
                const SizedBox(width: 16),
                Expanded(child: other),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        _AboutCard(db: db),
      ],
    );
  }
}

class _SourcesCard extends ConsumerStatefulWidget {
  const _SourcesCard({
    required this.sources,
    required this.db,
    required this.t,
  });
  final List<SourceLite> sources;
  final HubDatabase? db;
  final AppTokens t;

  @override
  ConsumerState<_SourcesCard> createState() => _SourcesCardState();
}

class _SourcesCardState extends ConsumerState<_SourcesCard> {
  List<SourceLite> _sources = const <SourceLite>[];
  final Map<String, Health> _health = <String, Health>{};

  /// 已经做过自动协议识别的源 id（每源至多一次，避免重复打扰第三方站点）
  final Set<String> _autoDetectTried = <String>{};

  @override
  void initState() {
    super.initState();
    _sources = widget.sources;
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoDetectPending());
  }

  @override
  void didUpdateWidget(covariant _SourcesCard old) {
    super.didUpdateWidget(old);
    _sources = widget.sources;
  }

  /// 自愈：历史遗留的自定义源（或被手工清掉 protocol 的源）进入设置页时，
  /// 后台补跑一次协议识别 —— 用户不必手动点「识别」，打开页面即修好。
  Future<void> _autoDetectPending() async {
    final db = widget.db;
    if (db == null || db.readOnly) return;
    for (final s in List<SourceLite>.from(_sources)) {
      if (!mounted) return;
      if (s.kind != ResourceKind.magnet) continue;
      if (s.config['protocol'] != null) continue;
      final addr = (s.config['baseUrl'] as String?) ?? '';
      if (addr.isEmpty) continue;
      if (!_autoDetectTried.add(s.id)) continue;
      HubLogger.i('源 ${s.id} 未登记协议，后台自动识别中…');
      final prober = SourceProber(
        proxy: ref.read(appSettingsProvider).network.proxy,
        timeoutMs: 12000,
      );
      ProbeResult? result;
      try {
        result = await prober.probe(
          addr,
          apiKey: (s.config['apiKey'] as String?) ?? '',
        );
      } catch (e) {
        HubLogger.w('源 ${s.id} 协议识别异常：$e');
      }
      if (result != null) {
        db.handle.execute(
          'UPDATE source_site SET config_json=? WHERE id=?',
          <Object?>[
            jsonEncode(<String, dynamic>{
              ...s.config,
              'protocol': result.protocol.id,
              'apiBase': result.apiBase,
            }),
            s.id,
          ],
        );
        HubLogger.i('源 ${s.id} 自动识别成功 → ${result.protocol.label}');
      } else {
        HubLogger.w('源 ${s.id} 自动识别失败：未命中任何已知协议');
      }
      if (!mounted) return;
      await _refresh();
    }
  }

  /// CJ1-0008-a 切换/新增/删除后重新读库并重建 UI
  Future<void> _refresh() async {
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

  /// 一键移除研发期遗留的演示源（含「演示 · 磁力源 A/B」「演示 · 115 分享源」）
  void _purgeDemoSources() {
    final db = widget.db;
    if (db == null || db.readOnly) {
      showHubToast(context, '数据库只读，无法清理演示源');
      return;
    }
    final n = db.handle.select(
      "SELECT COUNT(*) AS c FROM source_site WHERE config_json LIKE '%\"demo\":true%'",
    );
    final count = (n.first['c'] as num?)?.round() ?? 0;
    if (count == 0) {
      showHubToast(context, '没有需要清理的演示源');
      return;
    }
    db.handle.execute(
      "DELETE FROM source_site WHERE config_json LIKE '%\"demo\":true%'",
    );
    showHubToast(context, '已清理 $count 个演示源');
    _refresh();
  }

  /// 新增自定义源：入库后**立刻跑一次协议自动识别**并把结果写回，
  /// 避免「填了地址却因为协议不对而永远 404」。
  Future<void> _insertCustom(
    String name,
    ResourceKind kind,
    String addr,
  ) async {
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
    await _refresh();

    if (kind != ResourceKind.magnet) return;
    final r = await _detectProtocol(addr, id: id, cfg: cfg, silent: true);
    if (!mounted) return;
    showHubToast(
      context,
      r == null
          ? '未能自动识别「$name」的协议，可在列表中点「识别」重试'
          : '已识别：$name → ${r.label}（${r.sampleCount} 条样例）',
    );
    await _refresh();
  }

  /// 协议自动识别：按 Bitmagnet REST → GraphQL → Torznab → apibay → 网页抓取 依次试探
  Future<ProbeResult?> _detectProtocol(
    String addr, {
    required String id,
    required Map<String, dynamic> cfg,
    bool silent = false,
  }) async {
    final db = widget.db;
    if (db == null || db.readOnly) return null;
    final settings = ref.read(appSettingsProvider);
    final prober = SourceProber(
      proxy: settings.network.proxy,
      timeoutMs: 12000,
    );
    ProbeResult? result;
    try {
      result = await prober.probe(
        addr,
        apiKey: (cfg['apiKey'] as String?) ?? '',
      );
    } catch (e) {
      HubLogger.w('源 $id 协议识别异常：$e');
    }
    if (result == null) return null;

    final merged = <String, dynamic>{
      ...cfg,
      'protocol': result.protocol.id,
      'apiBase': result.apiBase,
    };
    db.handle.execute(
      'UPDATE source_site SET config_json=? WHERE id=?',
      <Object?>[jsonEncode(merged), id],
    );
    HubLogger.i('源 $id 协议识别成功 → ${result.protocol.label}');
    return ProbeResult(
      protocol: result.protocol,
      apiBase: result.apiBase,
      sampleCount: result.sampleCount,
    );
  }

  /// 给已有源（重新）识别协议
  Future<void> _redetect(SourceLite s) async {
    final addr = (s.config['baseUrl'] as String?) ?? '';
    if (addr.isEmpty) {
      showHubToast(context, '该源没有配置地址，无法识别');
      return;
    }
    showHubToast(context, '正在识别 ${s.name}…');
    final r = await _detectProtocol(addr, id: s.id, cfg: s.config);
    if (!mounted) return;
    showHubToast(
      context,
      r == null
          ? '未识别出「${s.name}」的协议（已尝试 5 种主流协议）'
          : '识别成功：${r.label} → ${r.apiBase}',
    );
    await _refresh();
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
            GhostButton(label: '取消', onPressed: () => Navigator.of(ctx).pop()),
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
      final check = adapter.healthCheck(ctx);
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
                child: Text(
                  '源适配器',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${_sources.where((e) => e.enabled).length}/${_sources.length} 启用',
                style: TextStyle(color: t.textDim, fontSize: 13),
              ),
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
                onDetect: s.kind == ResourceKind.magnet && canWrite
                    ? () => _redetect(s)
                    : null,
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
          if (_sources.any((e) => e.demo)) ...<Widget>[
            const SizedBox(height: 8),
            GhostButton(
              label: '清理遗留演示源',
              icon: Icons.cleaning_services_outlined,
              onPressed: canWrite ? _purgeDemoSources : null,
            ),
          ],
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
    this.onDetect,
  });
  final SourceLite source;
  final AppTokens t;
  final Health? health;
  final VoidCallback onProbe;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onDelete;

  /// 协议自动识别；仅磁力源有意义
  final VoidCallback? onDetect;

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
                Text(
                  source.name,
                  style: TextStyle(
                    color: t.textHi,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    Text(
                      '${source.kind.name} · 优先级 ${source.priority}',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                    if (source.demo)
                      Text(
                        '演示源',
                        style: TextStyle(color: t.warn, fontSize: 12),
                      ),
                    if (source.id.startsWith('custom-'))
                      Text(
                        '自定义',
                        style: TextStyle(color: t.cyan, fontSize: 12),
                      ),
                    Builder(
                      builder: (ctx) {
                        final p = SourceProtocol.tryParse(
                          source.config['protocol'] as String?,
                        );
                        if (p == null) {
                          return Text(
                            '协议未识别',
                            style: TextStyle(color: t.warn, fontSize: 12),
                          );
                        }
                        return Text(
                          p.label,
                          style: TextStyle(color: t.ok, fontSize: 12),
                        );
                      },
                    ),
                    if (health != null)
                      Text(
                        health!.ok ? '健康' : '异常：${health!.message}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: health!.ok ? t.ok : t.danger,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          GhostButton(label: '自检', onPressed: onProbe),
          if (onDetect != null) ...<Widget>[
            const SizedBox(width: 8),
            GhostButton(label: '识别', onPressed: onDetect),
          ],
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
  const _NetworkCard({
    required this.proxy,
    required this.maxResults,
    required this.concurrency,
    required this.onSave,
  });
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
          Text(
            '搜索与网络',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            textField: true,
            label: '代理地址',
            child: TextField(
              controller: proxy,
              decoration: const InputDecoration(
                hintText: '代理，如 127.0.0.1:7890（留空直连）',
              ),
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
          AccentButton(
            label: '保存',
            icon: Icons.save_outlined,
            onPressed: onSave,
          ),
        ],
      ),
    );
  }
}

/// 115 会话设置（W1）：选择登录「绑定设备槽位」，避免与网页端登录互相挤下线
class _Pan115Card extends ConsumerWidget {
  const _Pan115Card();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    final cfg = s.pan115;
    final app = pan115AppOf(cfg.loginApp);
    final ctl = ref.read(appSettingsProvider.notifier);

    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '115 会话',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '115 的登录会话按「设备槽位」区分：用「网页版」登录会把浏览器网页端顶下线。'
            '选一个你平时不占用的槽位（推荐小程序 / 电视端），即可与网页端同时在线、互不干扰。',
            style: TextStyle(color: t.textDim, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text('绑定设备', style: TextStyle(color: t.text)),
              ),
              HubDropdown<String>(
                label: '设备',
                minWidth: 220,
                items: kPan115Apps.map((a) => (a.id, a.label, true)).toList(),
                value: cfg.loginApp,
                onChanged: (v) {
                  ctl.patchPan115(cfg.copyWith(loginApp: v));
                  showHubToast(
                    context,
                    '下次扫码将绑定「${pan115AppOf(v).label.split('（').first}」',
                  );
                },
              ),
            ],
          ),
          if (app.conflicts) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.warn.withValues(alpha: 0.12),
                border: Border.all(color: t.warn.withValues(alpha: 0.45)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, size: 16, color: t.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '当前槽位会挤掉你在用的那一端，建议换成小程序或电视端。',
                      style: TextStyle(color: t.warn, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 26),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('轮询云端真实进度', style: TextStyle(color: t.text)),
                    Text(
                      '导入看板每 ${cfg.pollIntervalSeconds}s 拉一次 115 离线任务列表',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: cfg.pollCloudProgress,
                activeThumbColor: t.accent,
                onChanged: (v) =>
                    ctl.patchPan115(cfg.copyWith(pollCloudProgress: v)),
              ),
            ],
          ),
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
          Text(
            '首页推荐',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: Text('推荐总开关', style: TextStyle(color: t.text)),
              ),
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
                    Text(
                      'V1.1.0 将支持 TMDB / 自定义源',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              HubSegmented<String>(
                label: '首页数据源',
                items: const <(String, String)>[
                  ('douban', '豆瓣'),
                  ('tmdb', 'TMDB'),
                ],
                value: s.recommend.sourceId,
                onChanged: (v) {
                  if (v == 'tmdb') {
                    showHubToast(context, 'TMDB 源将在 V1.1.0 提供（当前仍走豆瓣）');
                    return;
                  }
                  ref
                      .read(appSettingsProvider.notifier)
                      .patchRecommend(s.recommend.copyWith(sourceId: v));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 启动页 id → 中文标签
String _startPageLabel(String id) => switch (id) {
  'overview' => '概览',
  'discover' => '发现',
  'search' => '搜索',
  'import' => '导入',
  'library' => '收藏库',
  'settings' => '设置',
  _ => '发现',
};

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
          Text(
            '数据与桌面',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: Text('退出自动备份', style: TextStyle(color: t.text)),
              ),
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
              Expanded(
                child: Text('关闭到托盘', style: TextStyle(color: t.text)),
              ),
              Switch(
                value: s.minimizeToTray,
                activeThumbColor: t.accent,
                onChanged: (v) => ref
                    .read(appSettingsProvider.notifier)
                    .update(s.copyWith(minimizeToTray: v)),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('启动默认页', style: TextStyle(color: t.text)),
                    const SizedBox(height: 2),
                    Text(
                      '下次启动生效；当前会话不受影响',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              HubDropdown<String>(
                minWidth: 132,
                items: StartPage.startPageIds.entries
                    .map((e) => (e.key, _startPageLabel(e.key), true))
                    .toList(growable: false),
                value: s.startPage,
                onChanged: (v) => ref
                    .read(appSettingsProvider.notifier)
                    .update(s.copyWith(startPage: v)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: AccentButton(
                  label: '立即备份',
                  icon: Icons.backup_outlined,
                  expand: true,
                  onPressed: db == null
                      ? null
                      : () async {
                          try {
                            final to = await db!.backup();
                            HubLogger.i('备份完成 $to');
                            if (context.mounted) {
                              showHubToast(context, '备份完成：$to');
                            }
                          } catch (e) {
                            HubLogger.e('备份失败', e);
                            if (context.mounted) {
                              showHubToast(context, '备份失败：$e');
                            }
                          }
                        },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GhostButton(
                  label: '最近日志',
                  icon: Icons.receipt_long_outlined,
                  onPressed: () => _showRecentLogs(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 现场排障用：把最近日志摊开给用户看 / 复制。
  ///
  /// 三版遗留的 `HubLogger.tail()` 终于有了调用点（V3-D2）。
  /// 【红线】日志本身不含凭证（logger.dart 明确不记录网络数据），
  /// 这里只读不写、只展示不落新文件。
  static Future<void> _showRecentLogs(BuildContext context) async {
    final lines = await HubLogger.tail(lines: 200);
    if (!context.mounted) return;
    final text = lines.isEmpty
        ? '日志为空或尚未写入（首次启动会立即开始记录）。\n'
              '位置：${HubLogger.instance.filePath}'
        : lines.join('\n');
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final t = ctx.t;
        return AlertDialog(
          backgroundColor: t.surfaceSolid,
          title: Text(
            '最近日志（${lines.length} 行）',
            style: TextStyle(color: t.textHi),
          ),
          content: SizedBox(
            width: 720,
            height: 420,
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: TextStyle(
                  color: t.text,
                  fontSize: 12.5,
                  fontFamily: 'Consolas',
                  height: 1.45,
                ),
              ),
            ),
          ),
          actions: <Widget>[
            GhostButton(
              label: '复制全部',
              icon: Icons.copy_all_outlined,
              onPressed: () async {
                await copyToClipboard(context, text);
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
            ),
            AccentButton(label: '关闭', onPressed: () => Navigator.of(ctx).pop()),
          ],
        );
      },
    );
  }
}

class _AboutCard extends ConsumerWidget {
  const _AboutCard({required this.db});
  final HubDatabase? db;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final rows = <(String, String)>[
      ('软件版本号', 'V${BuildInfo.appVersion}'),
      ('数据库版本号', 'user_version = ${db?.userVersion ?? '-'}'),
      ('SQLite 版本号', BuildInfo.sqliteVersion),
      ('Flutter 版本号', BuildInfo.flutterVersion),
      ('Dart 运行时', BuildInfo.dartVersion),
      ('原生基线版本号', BuildInfo.nativeVersion),
      ('操作系统', BuildInfo.osVersion),
    ];
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '关于',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              HubChip(
                label: db?.fts5Available == true ? 'FTS5 可用' : 'FTS5 不可用',
                selected: true,
                color: db?.fts5Available == true ? t.ok : t.warn,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: t.bg1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.border),
            ),
            child: Column(
              children: <Widget>[
                for (var i = 0; i < rows.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, color: t.border),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 132,
                          child: Text(
                            rows[i].$1,
                            style: TextStyle(color: t.textDim, fontSize: 13.5),
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            rows[i].$2,
                            style: TextStyle(
                              color: t.textHi,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
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

/// 界面布局：导航位置 / 导航标签 / 状态栏位置与内容开关
///
/// 修改即时生效（AppShell 直接消费 `AppSettings.shellLayout`）并落库。
class _ShellLayoutCard extends ConsumerWidget {
  const _ShellLayoutCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    final l = s.shellLayout;
    final ctl = ref.read(appSettingsProvider.notifier);

    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '界面布局',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text('即时生效', style: TextStyle(color: t.textDim, fontSize: 12.5)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('导航位置', style: TextStyle(color: t.text)),
                    Text(
                      '自动 = 窄屏落底栏，宽屏走侧栏',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              HubDropdown<NavPosition>(
                label: '导航',
                minWidth: 116,
                items: const <(NavPosition, String, bool)>[
                  (NavPosition.auto, '自动', true),
                  (NavPosition.left, '左侧栏', true),
                  (NavPosition.right, '右侧栏', true),
                  (NavPosition.bottom, '底部栏', true),
                ],
                value: l.navPosition,
                onChanged: (v) => ctl.patchShell(navPosition: v),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('导航标签', style: TextStyle(color: t.text)),
                    Text(
                      '关闭后仅显示图标，更省空间',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: l.showNavLabels,
                activeThumbColor: t.accent,
                onChanged: (v) => ctl.patchShell(showNavLabels: v),
              ),
            ],
          ),
          const Divider(height: 24),
          Row(
            children: <Widget>[
              Expanded(
                child: Text('状态栏位置', style: TextStyle(color: t.text)),
              ),
              const SizedBox(width: 12),
              HubSegmented<StatusBarPosition>(
                label: '状态栏位置',
                items: const <(StatusBarPosition, String)>[
                  (StatusBarPosition.top, '顶部'),
                  (StatusBarPosition.bottom, '底部'),
                  (StatusBarPosition.hidden, '隐藏'),
                ],
                value: l.statusBarPosition,
                onChanged: (v) => ctl.patchShell(statusBarPosition: v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '状态栏内容',
            style: TextStyle(
              color: t.textHi,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _ContentToggle(
                label: '当前页面',
                value: l.showStatusPage,
                onChanged: (v) => ctl.patchShell(showStatusPage: v),
              ),
              _ContentToggle(
                label: '数据库版本',
                value: l.showStatusDbVersion,
                onChanged: (v) => ctl.patchShell(showStatusDbVersion: v),
              ),
              _ContentToggle(
                label: 'FTS 状态',
                value: l.showStatusFts,
                onChanged: (v) => ctl.patchShell(showStatusFts: v),
              ),
              _ContentToggle(
                label: '应用版本',
                value: l.showStatusAppVersion,
                onChanged: (v) => ctl.patchShell(showStatusAppVersion: v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 状态栏内容开关（芯片形态，紧凑排布）
class _ContentToggle extends StatelessWidget {
  const _ContentToggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      toggled: value,
      label: '状态栏显示$label',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: value ? t.accent.withValues(alpha: 0.16) : t.bg1,
            border: Border.all(
              color: value ? t.accent.withValues(alpha: 0.55) : t.border,
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                value ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 14,
                color: value ? t.accent : t.textDim,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: value ? t.textHi : t.textDim,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主题模式：预设主题 / 自定义
enum _ThemeMode { preset, custom }

/// 多主题：先选「预设主题 / 自定义」模式，再展开对应细节
/// （此前一次铺开全部预设卡，入口太重；预设改由紧凑下拉选择）
class _ThemeCard extends ConsumerWidget {
  const _ThemeCard();

  /// 自定义主色候选（与预设主色互补，避免用户选到极难读的颜色）
  static const List<int> _swatches = <int>[
    0xFFFF7A2F, // 115 橙
    0xFFA78BFA, // 星云紫
    0xFF34D399, // 松林绿
    0xFF0EA5E9, // 海盐蓝
    0xFFF43F5E, // 玫瑰红
    0xFFFBBF24, // 琥珀黄
    0xFF22D3EE, // 青
    0xFF64748B, // 石墨灰
    0xFF8B5CF6, // 深紫
    0xFF14B8A6, // 碧
    0xFFEC4899, // 品红
    0xFF10B981, // 翡翠
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    final current = s.presetId;
    final notifier = ref.read(appSettingsProvider.notifier);
    final customMode = current == ThemePresetId.custom;

    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '主题',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '当前：${_presetLabel(current)}',
                style: TextStyle(color: t.textDim, fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 顶层只给两种模式，细节按需展开
          HubSegmented<_ThemeMode>(
            label: '主题模式',
            items: const <(_ThemeMode, String)>[
              (_ThemeMode.preset, '预设主题'),
              (_ThemeMode.custom, '自定义'),
            ],
            value: customMode ? _ThemeMode.custom : _ThemeMode.preset,
            onChanged: (v) {
              if (v == _ThemeMode.custom) {
                notifier.patchThemePreset(ThemePresetId.custom);
                return;
              }
              // 从「自定义」回到「预设主题」：落到默认预设，避免停在无效组合
              if (customMode) notifier.patchThemePreset(ThemePresetId.graphite);
            },
          ),
          const SizedBox(height: 12),
          if (!customMode) ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('配色', style: TextStyle(color: t.text)),
                      Text(
                        '内置预设随系统明暗自动适配',
                        style: TextStyle(color: t.textDim, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                HubDropdown<ThemePresetId>(
                  label: '配色',
                  minWidth: 150,
                  items: <(ThemePresetId, String, bool)>[
                    (ThemePresetId.system, '跟随系统', true),
                    for (final p in kThemePresets) (p.id, p.name, true),
                  ],
                  value: current,
                  onChanged: (v) => notifier.patchThemePreset(v),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _PresetPreview(preset: current),
          ],
          if (customMode) ...<Widget>[
            const SizedBox(height: 14),
            Divider(height: 1, color: t.border),
            const SizedBox(height: 12),
            Text(
              '明暗',
              style: TextStyle(
                color: t.textHi,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            HubSegmented<bool>(
              label: '明暗',
              items: const <(bool, String)>[(true, '深色'), (false, '浅色')],
              value: s.customDark,
              onChanged: (v) => notifier.patchCustomTheme(dark: v),
            ),
            const SizedBox(height: 14),
            Text(
              '主色',
              style: TextStyle(
                color: t.textHi,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final c in _swatches)
                  _Swatch(
                    value: c,
                    selected: s.customAccent == c,
                    onTap: () => notifier.patchCustomTheme(accent: c),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Text('色相微调', style: TextStyle(color: t.textDim, fontSize: 13)),
                const SizedBox(width: 10),
                Expanded(
                  child: Slider(
                    value: HSVColor.fromColor(Color(s.customAccent)).hue,
                    min: 0,
                    max: 360,
                    onChanged: (h) {
                      final cur = HSVColor.fromColor(Color(s.customAccent));
                      notifier.patchCustomTheme(
                        accent: cur.withHue(h).toColor().toARGB32(),
                      );
                    },
                  ),
                ),
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Color(s.customAccent),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: t.borderStrong),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 预设配色的一句话说明（卡片右上角「当前：xxx」）
String _presetLabel(ThemePresetId id) => switch (id) {
  ThemePresetId.system => '跟随系统',
  ThemePresetId.custom => '自定义',
  _ => presetById(id)?.name ?? '石墨极光',
};

/// 紧凑预设预览：三个主色点 + 说明，替代原来的「一排预设大卡」
class _PresetPreview extends StatelessWidget {
  const _PresetPreview({required this.preset});
  final ThemePresetId preset;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final tokens = resolveTokens(
      preset: preset,
      platformBrightness: Theme.of(context).brightness,
    );
    final desc = preset == ThemePresetId.system
        ? '深色/浅色随 OS'
        : (presetById(preset)?.desc ?? '内置配色');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: t.bg1,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          _Dot(color: tokens.bg0),
          const SizedBox(width: 6),
          _Dot(color: tokens.accent),
          const SizedBox(width: 6),
          _Dot(color: tokens.cyan),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textDim, fontSize: 12.5),
            ),
          ),
          Text(
            tokens.isDark ? '深色' : '浅色',
            style: TextStyle(color: t.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: context.t.borderStrong),
    ),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.value,
    required this.selected,
    required this.onTap,
  });
  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Tooltip(
      message:
          '#${value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Color(value),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? t.textHi : t.border,
              width: selected ? 2 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: selected
              ? const Icon(Icons.check, size: 16, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}
