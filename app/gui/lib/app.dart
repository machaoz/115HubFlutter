import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/db/hub_database.dart';
import 'state/providers.dart';
import 'ui/theme.dart';
import 'ui/app_shell.dart';
import 'navigation/app_routes.dart';

/// 导航项全部来自 `navigation/app_routes.dart` 的 `kAppPages`：
/// 新增页面只改那张表，本文件不动。
class Magnetic115HubApp extends ConsumerWidget {
  const Magnetic115HubApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(appDatabaseProvider);
    final settings = ref.watch(appSettingsProvider);

    // 跟随系统：OS 明暗可能在 App 之上（无 MediaQuery 祖先），做兜底
    final platformBrightness =
        MediaQuery.maybePlatformBrightnessOf(context) ??
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    // 正文字体族：设置里切「系统默认」时走平台回退链，其余用包内 HarmonyOS Sans。
    // 字体族是令牌的一部分（真源在 AppTokens.fontFamily），不再单独往下传，
    // 否则「设置里切了字体、UI 不重建」会复发。
    final tokens = resolveTokens(
      preset: settings.presetId,
      platformBrightness: platformBrightness,
      customDark: settings.customDark,
      customAccent: settings.customAccent,
      fontFamily: AppFontFamily.parse(settings.fontFamily),
    );
    final theme = buildTheme(tokens);

    return AppTokensScope(
      tokens: tokens,
      child: MaterialApp(
        title: 'Magnetic115Hub',
        debugShowCheckedModeBanner: false,
        theme: theme,
        darkTheme: theme,
        themeMode: ThemeMode.system,
        home: dbAsync.when(
          loading: () => const _Booting(),
          error: (e, _) => _BootError(err: e),
          data: (_) => AppShell(pages: kAppPages),
        ),
      ),
    );
  }
}

class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Scaffold(
      backgroundColor: t.bg0,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 启动/错误页品牌位与标题栏同源：定稿 logo 图片（UI-1 统一）
            Image.asset(
              'assets/brand/hub_mark_256.png',
              width: 44,
              height: 44,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(height: 16),
            CircularProgressIndicator(color: t.accent),
            const SizedBox(height: 12),
            Text('正在打开数据并迁移…', style: TextStyle(color: t.textDim)),
          ],
        ),
      ),
    );
  }
}

class _BootError extends ConsumerWidget {
  const _BootError({required this.err});
  final Object err;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: context.t.bg0,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: HubCardErrorCard(
            err: err,
            onRestore: () => ref.invalidate(appDatabaseProvider),
          ),
        ),
      ),
    );
  }
}

/// 启动失败卡片。
///
/// 崩溃后 SQLite 残留损坏的 -wal/-shm 是**可自愈**的，HubDatabase.open 已自动
/// 隔离并重试；走到这里说明库本身确实打不开。此时给出「从备份恢复」入口 ——
/// 只有死提示等于把用户挡在门外。
class HubCardErrorCard extends StatefulWidget {
  const HubCardErrorCard({super.key, required this.err, this.onRestore});

  final Object err;
  final VoidCallback? onRestore;

  @override
  State<HubCardErrorCard> createState() => _HubCardErrorCardState();
}

class _HubCardErrorCardState extends State<HubCardErrorCard> {
  List<File> _backups = const [];
  bool _scanned = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _scanBackups();
  }

  Future<void> _scanBackups() async {
    final ok = <File>[];
    for (final f in HubDatabase.listBackups()) {
      if (HubDatabase.verifyBackup(f)) ok.add(f);
    }
    if (!mounted) return;
    setState(() {
      _backups = ok;
      _scanned = true;
    });
  }

  Future<void> _restore(File b) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从备份恢复'),
        content: Text(
          '当前 hub.db 将被移入 backups/ 留档（不会删除），然后用该快照替换。\n\n'
          '快照：${b.path.split(RegExp(r'[/\\]')).last}\n\n'
          '恢复后需要重启程序。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      HubDatabase.restoreFrom(b);
      widget.onRestore?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('恢复失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // HubDbException 带面向用户的中文文案，裸异常才退回 toString
    final text = widget.err is HubDbException
        ? (widget.err as HubDbException).userMessage
        : widget.err.toString();

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: t.surface1,
        border: Border.all(color: t.danger),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.error_outline, color: t.danger),
              const SizedBox(width: 8),
              Text(
                '启动失败',
                style: TextStyle(
                  color: t.textHi,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(color: t.textDim)),
          const SizedBox(height: 12),
          Text(
            '数据位于 %APPDATA%\\Magnetic115Hub\\hub.db。',
            style: TextStyle(color: t.textDim, fontSize: 13),
          ),
          if (_scanned && _backups.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              '可用备份：',
              style: TextStyle(
                color: t.textHi,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final b in _backups)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.restore, color: t.textDim, size: 18),
                      title: Text(
                        b.path.split(RegExp(r'[/\\]')).last,
                        style: TextStyle(color: t.textDim, fontSize: 12),
                      ),
                      trailing: TextButton(
                        onPressed: _busy ? null : () => _restore(b),
                        child: const Text('恢复'),
                      ),
                    ),
                ],
              ),
            ),
          ] else if (_scanned) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'backups 目录下没有可用快照。',
              style: TextStyle(color: t.textDim, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}
