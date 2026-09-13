import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'theme.dart';
import 'widgets.dart';
import '../state/providers.dart';
import '../core/db/settings.dart';

/// 导航目标
class NavItem {
  const NavItem({required this.label, required this.icon, required this.page});
  final String label;
  final IconData icon;
  final Widget page;
}

/// 应用外壳：自定义标题栏 + 磁吸导航 + 状态栏
/// 记忆点：① 标题栏常驻「网络脉搏」② 导航激活项磁吸辉光滑动
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.pages});

  final List<NavItem> pages;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // P5 将改为「关闭到托盘」；当前按设置决定是否直接退出
    final minimize = ref.read(appSettingsProvider).minimizeToTray;
    if (minimize) await windowManager.hide();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final index = ref.watch(navIndexProvider);

    return Scaffold(
      backgroundColor: t.bg0,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.aurora),
        child: LayoutBuilder(builder: (context, c) {
          final compact = c.maxWidth < 1100;
          final narrow = c.maxWidth < 760;
          return Column(
            children: <Widget>[
              const _TitleBar(),
              Expanded(
                child: Row(
                  children: <Widget>[
                    if (!narrow)
                      _NavRail(
                        items: widget.pages,
                        index: index,
                        compact: compact,
                        onSelect: (i) =>
                            ref.read(navIndexProvider.notifier).select(i),
                      ),
                    Expanded(
                      child: IndexedStack(
                        index: index,
                        children: widget.pages.map((e) => e.page).toList(),
                      ),
                    ),
                  ],
                ),
              ),
              if (narrow)
                _BottomNav(
                  items: widget.pages,
                  index: index,
                  onSelect: (i) => ref.read(navIndexProvider.notifier).select(i),
                )
              else
                _StatusBar(index: index, items: widget.pages),
            ],
          );
        }),
      ),
    );
  }
}

// -------------------------------------------------------------------- 标题栏

class _TitleBar extends ConsumerWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final settings = ref.watch(appSettingsProvider);
    ref.watch(navIndexProvider); // 页面切换时重建，返回按钮显隐随之更新
    final nav = ref.read(navIndexProvider.notifier);
    return DragToMoveArea(
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: t.surfaceSolid.withValues(alpha: 0.92),
          border: Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: <Color>[t.accent, t.accent2]),
                borderRadius: BorderRadius.circular(9),
                boxShadow: <BoxShadow>[
                  BoxShadow(color: t.accent.withValues(alpha: 0.35), blurRadius: 12),
                ],
              ),
              alignment: Alignment.center,
              child: const Text('磁',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            const SizedBox(width: 10),
            Text(
              '磁聚·115Hub',
              style: TextStyle(
                color: t.textHi,
                fontWeight: FontWeight.w800,
                fontSize: 16.5,
                letterSpacing: 0.3,
              ),
            ),
            if (nav.canBack) ...<Widget>[
              const SizedBox(width: 10),
              Semantics(
                button: true,
                label: '返回上一级',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => nav.back(),
                  child: Container(
                    width: 34,
                    height: 30,
                    decoration: BoxDecoration(
                      color: t.surface,
                      border: Border.all(color: t.border),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Tooltip(
                      message: '返回上一级',
                      child: Icon(Icons.arrow_back, size: 15, color: t.text),
                    ),
                  ),
                ),
              ),
            ],
            const Spacer(),
            const _NetworkPulse(),
            _ThemeToggle(current: settings.theme),
            const SizedBox(width: 6),
            Row(
              children: <Widget>[
                _WinBtn(icon: Icons.remove, onTap: () => windowManager.minimize(), t: t),
                FutureBuilder<bool>(
                  future: windowManager.isMaximized(),
                  builder: (context, snap) => _WinBtn(
                    icon: Icons.crop_square,
                    t: t,
                    onTap: () async {
                      if (snap.data == true) {
                        await windowManager.unmaximize();
                      } else {
                        await windowManager.maximize();
                      }
                    },
                  ),
                ),
                _WinBtn(
                  icon: Icons.close,
                  t: t,
                  danger: true,
                  onTap: () => windowManager.close(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WinBtn extends StatelessWidget {
  const _WinBtn({required this.icon, required this.onTap, required this.t, this.danger = false});
  final IconData icon;
  final VoidCallback onTap;
  final AppTokens t;
  final bool danger;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Semantics(
          button: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Container(
              width: 34,
              height: 30,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border.all(color: t.border),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 15, color: danger ? t.danger : t.text),
            ),
          ),
        ),
      );
}

/// 记忆点：网络脉搏胶囊（实时吞吐 + 波形）
class _NetworkPulse extends StatefulWidget {
  const _NetworkPulse();

  @override
  State<_NetworkPulse> createState() => _NetworkPulseState();
}

class _NetworkPulseState extends State<_NetworkPulse>
    with SingleTickerProviderStateMixin {
  final List<double> _pts =
      List<double>.generate(26, (i) => 0.3 + math.Random(i).nextDouble() * 0.6);

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    final reduce = MediaQuery.of(context).disableAnimations;
    if (!reduce) {
      setState(() {
        _pts.removeAt(0);
        _pts.add(0.25 + math.Random().nextDouble() * 0.72);
      });
    }
    _tick();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.borderStrong),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: <Widget>[
          StatusDot(color: t.ok),
          const SizedBox(width: 8),
          Text('115 已连接',
              style: TextStyle(
                  color: t.textHi, fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          CustomPaint(
            size: const Size(54, 20),
            painter: _SparkPainter(_pts, t.cyan),
          ),
          const SizedBox(width: 6),
          Text('↓86.4 ↑12.1',
              style: TextStyle(color: t.textDim, fontSize: 11.5)),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.pts, this.color);
  final List<double> pts;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final x = i / (pts.length - 1) * size.width;
      final y = size.height - pts[i] * size.height * 0.88 - 1;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}

class _ThemeToggle extends ConsumerWidget {
  const _ThemeToggle({required this.current});
  final ThemeModePref current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final icon = switch (current) {
      ThemeModePref.dark => Icons.dark_mode_outlined,
      ThemeModePref.light => Icons.light_mode_outlined,
      ThemeModePref.system => Icons.brightness_auto_outlined,
    };
    return Tooltip(
      message: '主题：${current.name}（点击切换 深/浅/系统）',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          final order = ThemeModePref.values;
          final next = order[(order.indexOf(current) + 1) % order.length];
          ref.read(appSettingsProvider.notifier).patchTheme(next);
        },
        child: Container(
          width: 34,
          height: 30,
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 15, color: t.text),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- 导航栏

class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.items,
    required this.index,
    required this.compact,
    required this.onSelect,
  });

  final List<NavItem> items;
  final int index;
  final bool compact;
  final ValueChanged<int> onSelect;

  static const double _itemH = 46;
  static const double _itemGap = 6;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: compact ? 74 : 222,
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: 14),
      decoration: BoxDecoration(
        color: t.bg1.withValues(alpha: 0.55),
        border: Border(right: BorderSide(color: t.border)),
      ),
      child: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                // 磁吸辉光：随激活项滑动
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  top: 8 + index * (_itemH + _itemGap),
                  left: 0,
                  child: Container(
                    width: 3,
                    height: _itemH - 12,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[t.accent, t.accent2],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(3),
                      boxShadow: <BoxShadow>[
                        BoxShadow(color: t.accent, blurRadius: 14),
                      ],
                    ),
                  ),
                ),
                ListView.builder(
                  padding: const EdgeInsets.only(left: 10),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    final selected = i == index;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: _itemGap),
                      child: Semantics(
                        selected: selected,
                        button: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => onSelect(i),
                          child: Container(
                            height: _itemH,
                            padding: EdgeInsets.symmetric(
                                horizontal: compact ? 0 : 12),
                            alignment: compact
                                ? Alignment.center
                                : Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: selected ? t.surfaceSolid : Colors.transparent,
                              border: Border.all(
                                color: selected ? t.border : Colors.transparent,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: compact
                                ? Tooltip(
                                    message: it.label,
                                    child: Icon(it.icon,
                                        size: 20,
                                        color: selected ? t.textHi : t.textDim),
                                  )
                                : Row(
                                    children: <Widget>[
                                      Icon(it.icon,
                                          size: 20,
                                          color:
                                              selected ? t.textHi : t.textDim),
                                      const SizedBox(width: 12),
                                      Text(
                                        it.label,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color:
                                              selected ? t.textHi : t.textDim,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          HubCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('构建基线',
                    style: TextStyle(
                        color: t.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5)),
                const SizedBox(height: 3),
                Text('P0 · release\n库 user_version = 7',
                    style: TextStyle(color: t.textDim, fontSize: 11.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.items, required this.index, required this.onSelect});
  final List<NavItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      decoration: BoxDecoration(
        color: t.surfaceSolid.withValues(alpha: 0.95),
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: List.generate(items.length, (i) {
              final selected = i == index;
              return Expanded(
                child: InkWell(
                  onTap: () => onSelect(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(items[i].icon,
                          size: 20, color: selected ? t.accent : t.textDim),
                      const SizedBox(height: 3),
                      Text(items[i].label,
                          style: TextStyle(
                              fontSize: 11,
                              color: selected ? t.accent : t.textDim)),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.index, required this.items});
  final int index;
  final List<NavItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final dbAsync = ref.watch(appDatabaseProvider);
    final ver = dbAsync.maybeWhen(data: (d) => d.userVersion.toString(), orElse: () => '…');
    final fts = dbAsync.maybeWhen(data: (d) => d.fts5Available, orElse: () => false);
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: t.bg1.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          Text('当前 ${items[index].label}',
              style: TextStyle(color: t.textDim, fontSize: 12.5)),
          const SizedBox(width: 18),
          Text('库 v$ver', style: TextStyle(color: t.textDim, fontSize: 12.5)),
          const SizedBox(width: 14),
          Icon(fts ? Icons.verified_outlined : Icons.warning_amber_outlined,
              size: 13, color: fts ? t.ok : t.warn),
          const SizedBox(width: 4),
          Text(fts ? 'FTS5 可用' : 'FTS5 不可用（LIKE 兜底）',
              style: TextStyle(
                  color: fts ? t.ok : t.warn, fontSize: 12.5)),
          const Spacer(),
          Text('Magnetic115Hub 1.0.1 · Windows 10/11 x64',
              style: TextStyle(color: t.textDim, fontSize: 12.5)),
        ],
      ),
    );
  }
}
