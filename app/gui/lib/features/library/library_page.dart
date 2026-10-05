import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/hub_database.dart';
import '../../core/db/repos.dart';
import '../../core/util/logger.dart';
import '../../sources/source.dart';
import '../../state/providers.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final TextEditingController _q = TextEditingController();
  String _group = '全部';
  List<ResourceItem> _items = const <ResourceItem>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _refresh() {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return;
    final repo = FavoritesRepo(db);
    setState(() {
      _items = _q.text.trim().isEmpty
          ? repo.list(group: _group == '全部' ? '' : _group)
          : repo.search(_q.text.trim());
    });
  }

  List<String> _groups() {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return const <String>[];
    return <String>['全部', ...FavoritesRepo(db).groups()];
  }

  String _export(List<ResourceItem> items, ExportFormat fmt) {
    switch (fmt) {
      case ExportFormat.text:
        return items.map((e) => '${e.title}\t${e.copyTarget}').join('\n');
      case ExportFormat.csv:
        final rows = <String>[
          '"标题","类型","容量","链接"',
          for (final e in items)
            '"${e.title.replaceAll('"', '""')}","${e.kind.name}","${fmtBytes(e.sizeBytes)}","${e.copyTarget}"',
        ];
        // UTF-8 BOM，Excel 直接双击不乱码（对齐 Electron 版口径）
        return '﻿${rows.join('\r\n')}';
      case ExportFormat.pan115:
        return items
            .where((e) => e.secLink != null)
            .map((e) => e.secLink!)
            .join('\n');
    }
  }

  Future<void> _doExport(ExportFormat fmt) async {
    if (_items.isEmpty) {
      showHubToast(context, '没有可导出的收藏');
      return;
    }
    final text = _export(_items, fmt);
    await copyToClipboard(
      context,
      text,
      successLabel: '已复制 ${_items.length} 条到剪贴板（${fmt.name}）',
    );
    HubLogger.i('导出 ${fmt.name}，共 ${_items.length} 条');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final db = ref.watch(appDatabaseProvider).maybeValue;
    final fts = db?.fts5TrigramAvailable ?? false;
    final groups = _groups();

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        Text('收藏库', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          fts
              ? 'FTS5 trigram 全文检索（≥3 字）+ LIKE 兜底 · 分组 · 三格式导出'
              : '当前 SQLite 无 FTS5 trigram，检索退化为 LIKE（功能不降级，效率略低）',
          style: TextStyle(color: fts ? t.textDim : t.warn),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 300,
              child: Semantics(
                textField: true,
                label: '收藏检索',
                child: TextField(
                  controller: _q,
                  onChanged: (_) => _refresh(),
                  decoration: const InputDecoration(
                    hintText: '检索收藏（如：诺兰 / Oppenheimer）',
                    prefixIcon: Icon(Icons.filter_alt_outlined, size: 19),
                  ),
                ),
              ),
            ),
            for (final g in groups)
              HubChip(
                label: g,
                selected: g == _group,
                onTap: () {
                  setState(() => _group = g);
                  _refresh();
                },
              ),
            GhostButton(
              label: '文本',
              icon: Icons.article_outlined,
              onPressed: () => _doExport(ExportFormat.text),
            ),
            GhostButton(
              label: 'CSV',
              icon: Icons.table_rows_outlined,
              onPressed: () => _doExport(ExportFormat.csv),
            ),
            GhostButton(
              label: '115://',
              icon: Icons.bolt_outlined,
              onPressed: () => _doExport(ExportFormat.pan115),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (_items.isEmpty)
          HubCard(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Text(
                  '还没有收藏。可在「搜索」页对结果点「★」加入收藏。',
                  style: TextStyle(color: t.textDim),
                ),
              ),
            ),
          )
        else
          HubCard(
            padding: EdgeInsets.zero,
            child: LayoutBuilder(
              builder: (context, c) {
                if (c.maxWidth < 680) {
                  // 窄屏转卡片视图
                  return Column(
                    children: _items
                        .map(
                          (it) =>
                              _CardTile(item: it, db: db, onRefresh: _refresh),
                        )
                        .toList(),
                  );
                }
                return _Table(items: _items, db: db, onRefresh: _refresh);
              },
            ),
          ),
      ],
    );
  }
}

enum ExportFormat { text, csv, pan115 }

/// 窄屏（<680px）卡片视图：表格塌缩为单列卡片
class _CardTile extends StatelessWidget {
  const _CardTile({
    required this.item,
    required this.db,
    required this.onRefresh,
  });

  final ResourceItem item;
  final HubDatabase? db;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.bg1,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            item.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.textHi, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: <Widget>[
              Text(
                item.kind == ResourceKind.pan115 ? '秒传' : '磁力',
                style: TextStyle(color: t.textDim, fontSize: 12.5),
              ),
              Text(
                fmtBytes(item.sizeBytes),
                style: TextStyle(color: t.textDim, fontSize: 12.5),
              ),
              Text(
                item.groupName,
                style: TextStyle(color: t.textDim, fontSize: 12.5),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              _MiniBtn(
                icon: Icons.copy_all_outlined,
                t: t,
                label: '复制',
                onTap: () => copyToClipboard(context, item.copyTarget),
              ),
              const SizedBox(width: 8),
              _MiniBtn(
                icon: Icons.delete_outline,
                t: t,
                label: '删除',
                danger: true,
                onTap: () {
                  if (db == null) return;
                  FavoritesRepo(db!).delete(item.favoriteKey);
                  onRefresh();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({
    required this.items,
    required this.db,
    required this.onRefresh,
  });
  final List<ResourceItem> items;
  final HubDatabase? db;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: TextStyle(
          color: t.textDim,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
        dataTextStyle: TextStyle(color: t.text, fontSize: 14.5),
        columns: <DataColumn>[
          const DataColumn(label: Text('名称')),
          const DataColumn(label: Text('类型')),
          const DataColumn(label: Text('分组')),
          const DataColumn(label: Text('容量')),
          const DataColumn(label: Text('去重键')),
          const DataColumn(label: Text('操作')),
        ],
        rows: items.map((it) {
          return DataRow(
            cells: <DataCell>[
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Text(
                    it.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textHi,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              DataCell(Text(it.kind == ResourceKind.pan115 ? '秒传' : '磁力')),
              DataCell(Text(it.groupName)),
              DataCell(Text(fmtBytes(it.sizeBytes))),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    it.favoriteKey,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.textDim, fontSize: 12.5),
                  ),
                ),
              ),
              DataCell(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _MiniBtn(
                      icon: Icons.copy_all_outlined,
                      t: t,
                      label: '复制',
                      onTap: () => copyToClipboard(context, it.copyTarget),
                    ),
                    const SizedBox(width: 8),
                    _MiniBtn(
                      icon: Icons.delete_outline,
                      t: t,
                      label: '删除',
                      danger: true,
                      onTap: () {
                        if (db == null) return;
                        FavoritesRepo(db!).delete(it.favoriteKey);
                        onRefresh();
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  const _MiniBtn({
    required this.icon,
    required this.t,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final AppTokens t;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: t.surface,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(9),
        ),
        alignment: Alignment.center,
        child: Tooltip(
          message: label,
          child: Icon(icon, size: 17, color: danger ? t.danger : t.textHi),
        ),
      ),
    ),
  );
}
