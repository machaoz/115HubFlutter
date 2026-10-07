import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sources/protocols.dart';
import '../../../sources/source.dart';
import '../../../sources/source_list.dart';
import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 源适配器设置域
///
/// 【P0-6】本分区不再接触 `HubDatabase`，也不自己拼 SQL：
/// 数据来自 `ref.watch(sourceListProvider)`，写操作走同一个 controller 的方法。
/// 原先这里的 5 段裸 SQL + 2 次 `setState` 回读 + 网络自检，全部下沉到
/// `SourceListController`；裸 SQL 归 `SourceRepo` 的 4 个新方法。
class SourcesSection extends ConsumerStatefulWidget {
  const SourcesSection({super.key});

  @override
  ConsumerState<SourcesSection> createState() => _SourcesSectionState();
}

class _SourcesSectionState extends ConsumerState<SourcesSection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(sourceListProvider.notifier).healPendingProtocols();
    });
  }

  SourceListController get _ctl => ref.read(sourceListProvider.notifier);

  Future<void> _toggle(SourceLite s, bool v) async {
    _ctl.setEnabled(s.id, v);
  }

  void _deleteCustom(String id) {
    if (!_ctl.canWrite) {
      showHubToast(context, '数据库只读，无法删除自定义源');
      return;
    }
    if (!_ctl.deleteCustom(id)) {
      showHubToast(context, '内置源不可删除');
      return;
    }
    showHubToast(context, '已删除自定义源');
  }

  /// 一键移除研发期遗留的演示源（含「演示 · 磁力源 A/B」「演示 · 115 分享源」）
  void _purgeDemoSources() {
    if (!_ctl.canWrite) {
      showHubToast(context, '数据库只读，无法清理演示源');
      return;
    }
    final n = _ctl.purgeDemo();
    showHubToast(context, n == 0 ? '没有需要清理的演示源' : '已清理 $n 个演示源');
  }

  /// 新增自定义源：入库后**立刻跑一次协议自动识别**并把结果写回，
  /// 避免「填了地址却因为协议不对而永远 404」。
  Future<void> _insertCustom(
    String name,
    ResourceKind kind,
    String addr,
  ) async {
    if (!_ctl.canWrite) {
      showHubToast(context, '数据库只读，无法写入自定义源');
      return;
    }
    final id = _ctl.insertCustom(name: name, kind: kind, addr: addr);
    if (id == null) {
      showHubToast(context, '新增失败，请稍后重试');
      return;
    }
    showHubToast(context, '已新增自定义源：$name');
    if (kind != ResourceKind.magnet) return;
    if (!mounted) return;

    final added = ref
        .read(sourceListProvider)
        .sources
        .where((e) => e.id == id)
        .toList(growable: false);
    final r = added.isEmpty ? null : await _ctl.detectProtocol(added.first);
    if (!mounted) return;
    showHubToast(
      context,
      r == null
          ? '未能自动识别「$name」的协议，可在列表中点「识别」重试'
          : '已识别：$name → ${r.label}（${r.sampleCount} 条样例）',
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
    final r = await _ctl.detectProtocol(s);
    if (!mounted) return;
    showHubToast(
      context,
      r == null
          ? '未识别出「${s.name}」的协议（已尝试 5 种主流协议）'
          : '识别成功：${r.label} → ${r.apiBase}',
    );
  }

  void _showAddDialog() {
    if (!_ctl.canWrite) {
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
          backgroundColor: ctx.t.surface1,
          title: Text('新增自定义源', style: TextStyle(color: ctx.t.textHi)),
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
    await _ctl.probeHealth(s);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final list = ref.watch(sourceListProvider);
    final sources = list.sources;
    final canWrite = _ctl.canWrite;
    final hasDb = ref.watch(appDatabaseProvider).maybeValue != null;
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
                '${sources.where((e) => e.enabled).length}/${sources.length} 启用',
                style: TextStyle(color: t.textDim, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (sources.isEmpty)
            Text('没有源记录（迁移未完成？）', style: TextStyle(color: t.warn))
          else
            for (final s in sources)
              _SourceTile(
                source: s,
                t: t,
                health: list.health[s.id],
                onProbe: () => _probe(s),
                onDetect: s.kind == ResourceKind.magnet && canWrite
                    ? () => _redetect(s)
                    : null,
                onToggle: hasDb ? (v) => _toggle(s, v) : null,
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
          if (sources.any((e) => e.demo)) ...<Widget>[
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
