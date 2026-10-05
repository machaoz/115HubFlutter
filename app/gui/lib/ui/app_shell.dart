import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'theme.dart';
import 'widgets.dart';
import '../core/util/version.dart';
import '../state/providers.dart';
import '../state/session.dart';
import '../core/db/settings.dart';

/// 导航目标
///
/// [icon] 为常态图标，[activeIcon] 为激活态图标（通常为 filled 版本）：
/// 点击后由 [_NavIcon] 做交叉淡入 + 缩放切换，让「我在哪一页」一眼可辨。
class NavItem {
  const NavItem({
    required this.label,
    required this.icon,
    required this.page,
    this.activeIcon,
    this.spinOnActivate = false,
  });
  final String label;
  final IconData icon;
  final Widget page;

  /// 激活态图标；未指定时退化为 [icon]
  final IconData? activeIcon;

  /// 激活时图标旋转一圈（设置齿轮的记忆点）
  final bool spinOnActivate;
}

/// auto 的真实落位：窄屏（<760）落底栏，否则左侧栏
NavPosition resolveNavPosition(NavPosition pref, double width) {
  if (pref != NavPosition.auto) return pref;
  return width < 760 ? NavPosition.bottom : NavPosition.left;
}

/// 应用外壳：自定义标题栏 + 磁吸导航 + 状态栏
/// 记忆点：① 标题栏常驻「网络脉搏」② 导航激活项磁吸辉光滑动
/// 布局由 `AppSettings.shellLayout` 驱动（导航位置 / 标签 / 状态栏位置与内容）
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
    final layout = ref.watch(appSettingsProvider).shellLayout;

    return Scaffold(
      backgroundColor: t.bg0,
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: t.aurora),
        child: LayoutBuilder(
          builder: (context, c) {
            final nav = resolveNavPosition(layout.navPosition, c.maxWidth);
            // 无标签或窗口偏窄 → 图标模式（74px），否则展开标签（222px）
            final iconOnly = !layout.showNavLabels || c.maxWidth < 1100;
            final showStatus =
                layout.statusBarPosition != StatusBarPosition.hidden &&
                layout.hasStatusContent;

            return Column(
              children: <Widget>[
                const _TitleBar(),
                if (showStatus &&
                    layout.statusBarPosition == StatusBarPosition.top)
                  _StatusBar(
                    index: index,
                    items: widget.pages,
                    layout: layout,
                    onTop: true,
                  ),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      if (nav == NavPosition.left)
                        _NavRail(
                          items: widget.pages,
                          index: index,
                          iconOnly: iconOnly,
                          onSelect: (i) =>
                              ref.read(navIndexProvider.notifier).select(i),
                        ),
                      Expanded(
                        child: _PageSwitchTransition(
                          index: index,
                          child: IndexedStack(
                            index: index,
                            children: widget.pages.map((e) => e.page).toList(),
                          ),
                        ),
                      ),
                      if (nav == NavPosition.right)
                        _NavRail(
                          items: widget.pages,
                          index: index,
                          iconOnly: iconOnly,
                          alignRight: true,
                          onSelect: (i) =>
                              ref.read(navIndexProvider.notifier).select(i),
                        ),
                    ],
                  ),
                ),
                if (showStatus &&
                    layout.statusBarPosition == StatusBarPosition.bottom)
                  _StatusBar(index: index, items: widget.pages, layout: layout),
                if (nav == NavPosition.bottom)
                  _BottomNav(
                    items: widget.pages,
                    index: index,
                    showLabels: layout.showNavLabels,
                    onSelect: (i) =>
                        ref.read(navIndexProvider.notifier).select(i),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 页面切换动效：轻量淡入 + 位移。
///
/// 【保状态】IndexedStack 以 `child` 形式挂在动画外层，切换时**不重建**，
/// 各页面的滚动位置 / 输入 / 加载态全部保留；只有透明度与位移参与补间。
class _PageSwitchTransition extends StatefulWidget {
  const _PageSwitchTransition({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_PageSwitchTransition> createState() => _PageSwitchTransitionState();
}

class _PageSwitchTransitionState extends State<_PageSwitchTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1, // 首帧不播动画
  );
  late final Animation<double> _ease = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
  );

  @override
  void didUpdateWidget(covariant _PageSwitchTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index) return;
    // 直接跳回起点（不触发构建），随后 forward 由 ticker 驱动后续帧
    _c.value = 0;
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ease,
    builder: (context, child) => Opacity(
      opacity: 0.4 + 0.6 * _ease.value,
      child: Transform.translate(
        offset: Offset(0, 12 * (1 - _ease.value)),
        child: child,
      ),
    ),
    child: widget.child,
  );
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
                  BoxShadow(
                    color: t.accent.withValues(alpha: 0.35),
                    blurRadius: 12,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: const Text(
                '磁',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
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
            const _SessionPulse(),
            _ThemePicker(current: settings.presetId),
            const SizedBox(width: 6),
            Row(
              children: <Widget>[
                _WinBtn(
                  icon: Icons.remove,
                  onTap: () => windowManager.minimize(),
                  t: t,
                ),
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
  const _WinBtn({
    required this.icon,
    required this.onTap,
    required this.t,
    this.danger = false,
  });
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

/// 会话状态胶囊：真实反映 115 登录态（此前为硬编码「已连接 + 假带宽」，已移除）
class _SessionPulse extends ConsumerWidget {
  const _SessionPulse();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(sessionProvider);
    final (Color color, String text) = switch (s.phase) {
      SessionPhase.loggedIn => (t.ok, '115 已登录'),
      SessionPhase.failed ||
      SessionPhase.expired => (t.danger, '115 ${s.phase.label}'),
      SessionPhase.fetchingQr ||
      SessionPhase.waitingScan ||
      SessionPhase.scanned => (t.cyan, '115 ${s.phase.label}'),
      SessionPhase.idle => (t.textDim, '115 未登录'),
    };
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
          StatusDot(color: color),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: t.textHi,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 标题栏主题入口：**只给两个入口**（预设主题 / 自定义），
/// 点击后导航到设置页并把对应的模式/状态切换好 —— 不在此罗列全部配色。
class _ThemePicker extends ConsumerWidget {
  const _ThemePicker({required this.current});
  final ThemePresetId current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final label = switch (current) {
      ThemePresetId.system => '跟随系统',
      ThemePresetId.custom => '自定义',
      _ => presetById(current)?.name ?? '主题',
    };
    final settingsIndex = StartPage.startPageIndex('settings');
    return PopupMenuButton<_ThemeEntry>(
      tooltip: '主题：$label',
      position: PopupMenuPosition.under,
      color: t.surfaceSolid,
      onSelected: (v) {
        final ctl = ref.read(appSettingsProvider.notifier);
        // 从「自定义」切回「预设主题」时落到默认预设，保证模式与状态一致
        if (v == _ThemeEntry.preset && current == ThemePresetId.custom) {
          ctl.patchThemePreset(ThemePresetId.graphite);
        }
        if (v == _ThemeEntry.custom) {
          ctl.patchThemePreset(ThemePresetId.custom);
        }
        ref.read(navIndexProvider.notifier).select(settingsIndex);
      },
      itemBuilder: (context) => <PopupMenuEntry<_ThemeEntry>>[
        PopupMenuItem<_ThemeEntry>(
          value: _ThemeEntry.preset,
          child: _MenuRow(
            label: '预设主题…',
            desc: '内置配色',
            color: t.cyan,
            selected: current != ThemePresetId.custom,
          ),
        ),
        PopupMenuItem<_ThemeEntry>(
          value: _ThemeEntry.custom,
          child: _MenuRow(
            label: '自定义主题…',
            desc: '自选明暗与主色',
            color: t.accent,
            selected: current == ThemePresetId.custom,
          ),
        ),
      ],
      child: Semantics(
        button: true,
        label: '主题设置，当前 $label',
        child: Container(
          width: 34,
          height: 30,
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.border),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Icon(
            current == ThemePresetId.system
                ? Icons.brightness_auto_outlined
                : Icons.palette_outlined,
            size: 15,
            color: t.text,
          ),
        ),
      ),
    );
  }
}

/// 标题栏主题入口的两项（刻意不展开全部预设）
enum _ThemeEntry { preset, custom }

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.label,
    required this.desc,
    required this.color,
    required this.selected,
  });
  final String label;
  final String desc;
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: <Widget>[
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: t.borderStrong),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            color: t.textHi,
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Text(desc, style: TextStyle(color: t.textDim, fontSize: 12)),
        if (selected) ...<Widget>[
          const SizedBox(width: 8),
          Icon(Icons.check, size: 15, color: t.accent),
        ],
      ],
    );
  }
}

// -------------------------------------------------------------------- 导航栏

/// 导航图标：常态 ↔ 激活态交叉切换（缩放 + 淡入），激活时齿轮旋转一圈
class _NavIcon extends StatelessWidget {
  const _NavIcon({
    required this.item,
    required this.selected,
    required this.color,
  });

  final NavItem item;
  final bool selected;
  final Color color;

  /// 侧栏/底栏统一图标尺寸
  static const double _size = 20;

  @override
  Widget build(BuildContext context) {
    final data = (selected ? item.activeIcon : item.icon) ?? item.icon;
    return AnimatedRotation(
      turns: item.spinOnActivate && selected ? 1 : 0,
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      child: AnimatedScale(
        scale: selected ? 1.08 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: Tween<double>(begin: 0.8, end: 1).animate(anim),
            child: FadeTransition(opacity: anim, child: child),
          ),
          child: Icon(
            data,
            key: ValueKey<IconData>(data),
            size: _size,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.items,
    required this.index,
    required this.iconOnly,
    required this.onSelect,
    this.alignRight = false,
  });

  final List<NavItem> items;
  final int index;
  final bool iconOnly;
  final ValueChanged<int> onSelect;

  /// true → 贴在内容区右侧（边框与磁吸条镜像）
  final bool alignRight;

  static const double _itemH = 46;
  static const double _itemGap = 6;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: iconOnly ? 74 : 222,
      padding: EdgeInsets.symmetric(
        horizontal: iconOnly ? 8 : 10,
        vertical: 14,
      ),
      decoration: BoxDecoration(
        color: t.bg1.withValues(alpha: 0.55),
        border: alignRight
            ? Border(left: BorderSide(color: t.border))
            : Border(right: BorderSide(color: t.border)),
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
                  left: alignRight ? null : 0,
                  right: alignRight ? 0 : null,
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
                  padding: EdgeInsets.only(
                    left: alignRight ? 0 : 10,
                    right: alignRight ? 10 : 0,
                  ),
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
                              horizontal: iconOnly ? 0 : 12,
                            ),
                            alignment: iconOnly
                                ? Alignment.center
                                : Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: selected
                                  ? t.surfaceSolid
                                  : Colors.transparent,
                              border: Border.all(
                                color: selected ? t.border : Colors.transparent,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: iconOnly
                                ? Tooltip(
                                    message: it.label,
                                    child: _NavIcon(
                                      item: it,
                                      selected: selected,
                                      color: selected ? t.textHi : t.textDim,
                                    ),
                                  )
                                : Row(
                                    children: <Widget>[
                                      _NavIcon(
                                        item: it,
                                        selected: selected,
                                        color: selected ? t.textHi : t.textDim,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          it.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: selected
                                                ? t.textHi
                                                : t.textDim,
                                          ),
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
        ],
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.items,
    required this.index,
    required this.showLabels,
    required this.onSelect,
  });
  final List<NavItem> items;
  final int index;
  final bool showLabels;
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
          height: showLabels ? 62 : 54,
          child: Row(
            children: List.generate(items.length, (i) {
              final selected = i == index;
              final it = items[i];
              return Expanded(
                child: Semantics(
                  selected: selected,
                  button: true,
                  child: InkWell(
                    onTap: () => onSelect(i),
                    child: Tooltip(
                      message: it.label,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          _NavIcon(
                            item: it,
                            selected: selected,
                            color: selected ? t.accent : t.textDim,
                          ),
                          if (showLabels) ...<Widget>[
                            const SizedBox(height: 3),
                            Text(
                              it.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: selected ? t.accent : t.textDim,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
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

/// 状态栏：位置（顶/底/隐藏）与内容开关均由 `ShellLayoutSettings` 驱动
class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.index,
    required this.items,
    required this.layout,
    this.onTop = false,
  });
  final int index;
  final List<NavItem> items;
  final ShellLayoutSettings layout;
  final bool onTop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final dbAsync = ref.watch(appDatabaseProvider);
    final ver = dbAsync.maybeWhen(
      data: (d) => d.userVersion.toString(),
      orElse: () => '…',
    );
    final fts = dbAsync.maybeWhen(
      data: (d) => d.fts5Available,
      orElse: () => false,
    );

    final left = <Widget>[
      if (layout.showStatusPage) _StatusText('当前 ${items[index].label}', t),
      if (layout.showStatusDbVersion) _StatusText('库 v$ver', t),
      if (layout.showStatusFts)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              fts ? Icons.verified_outlined : Icons.warning_amber_outlined,
              size: 13,
              color: fts ? t.ok : t.warn,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                fts ? 'FTS5 可用' : 'FTS5 不可用（LIKE 兜底）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fts ? t.ok : t.warn, fontSize: 12.5),
              ),
            ),
          ],
        ),
    ];
    final row = <Widget>[];
    for (var i = 0; i < left.length; i++) {
      if (i > 0) row.add(const SizedBox(width: 16));
      row.add(Flexible(child: left[i]));
    }

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: t.bg1.withValues(alpha: 0.6),
        border: onTop
            ? Border(bottom: BorderSide(color: t.border))
            : Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          ...row,
          const Spacer(),
          if (layout.showStatusAppVersion)
            _StatusText('磁聚·115Hub v${BuildInfo.appVersion}', t),
        ],
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText(this.text, this.t);
  final String text;
  final AppTokens t;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(color: t.textDim, fontSize: 12.5),
  );
}
