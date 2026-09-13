import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/providers.dart';
import 'ui/theme.dart';
import 'ui/app_shell.dart';
import 'core/db/settings.dart';
import 'features/overview/overview_page.dart';
import 'features/discover/discover_page.dart';
import 'features/search/search_page.dart';
import 'features/import/import_page.dart';
import 'features/library/library_page.dart';
import 'features/settings/settings_page.dart';

class Magnetic115HubApp extends ConsumerWidget {
  const Magnetic115HubApp({super.key});

  static const List<NavItem> _pages = <NavItem>[
    NavItem(label: '概览', icon: Icons.space_dashboard_outlined, page: OverviewPage()),
    NavItem(label: '发现', icon: Icons.grid_view_outlined, page: DiscoverPage()),
    NavItem(label: '搜索', icon: Icons.search, page: SearchPage()),
    NavItem(
        label: '导入',
        icon: Icons.download_for_offline_outlined,
        page: ImportPage()),
    NavItem(label: '收藏库', icon: Icons.star_outline, page: LibraryPage()),
    NavItem(label: '设置', icon: Icons.settings_outlined, page: SettingsPage()),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dbAsync = ref.watch(appDatabaseProvider);
    final settings = ref.watch(appSettingsProvider);

    return MaterialApp(
      title: 'Magnetic115Hub',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(AppTokens.light),
      darkTheme: buildTheme(AppTokens.dark),
      themeMode: switch (settings.theme) {
        ThemeModePref.dark => ThemeMode.dark,
        ThemeModePref.light => ThemeMode.light,
        ThemeModePref.system => ThemeMode.system,
      },
      home: dbAsync.when(
        loading: () => const _Booting(),
        error: (e, _) => _BootError(err: e.toString()),
        data: (_) => const AppShell(pages: _pages),
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
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: <Color>[t.accent, t.accent2]),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: const Text('磁',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
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

class _BootError extends StatelessWidget {
  const _BootError({required this.err});
  final String err;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Scaffold(
      backgroundColor: t.bg0,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: HubCardErrorCard(err: err),
        ),
      ),
    );
  }
}

class HubCardErrorCard extends StatelessWidget {
  const HubCardErrorCard({super.key, required this.err});
  final String err;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: t.surfaceSolid,
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
              Text('启动失败',
                  style: TextStyle(
                      color: t.textHi, fontSize: 18, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          Text(err, style: TextStyle(color: t.textDim)),
          const SizedBox(height: 12),
          Text(
            '数据位于 %APPDATA%\\Magnetic115Hub\\hub.db，'
            '可用 backups 目录下的快照恢复。',
            style: TextStyle(color: t.textDim, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
