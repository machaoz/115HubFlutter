import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/settings.dart';
import '../../../core/util/logger.dart';
import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 数据与桌面设置域
///
/// 数据库句柄由 `ref.watch(appDatabaseProvider)` 现取（P0-6），
/// 不再由父级注入 `HubDatabase?` —— 本分区因此不需要任何构造参数。
class DataSection extends ConsumerWidget {
  const DataSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    final db = ref.watch(appDatabaseProvider).maybeValue;
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
                // 单一来源：id 与中文标签都来自 AppRoute，候选集由 StartPage
                // 保证只含可见路由（未完工页面不会出现在这里）。
                // 用 startPageOptions 而不是 startPageRoutes：后者返回 AppRoute，
                // 读 .id/.label 需要额外 import app_route.dart 里的 AppRouteX 扩展
                items: StartPage.startPageOptions
                    .map((o) => (o.id, o.label, true))
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
                            final to = await db.backup();
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
          backgroundColor: t.surface1,
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
