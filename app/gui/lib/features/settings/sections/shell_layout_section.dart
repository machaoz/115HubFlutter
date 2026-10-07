import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/settings.dart';
import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 界面布局设置域：导航位置 / 导航标签 / 状态栏位置与内容开关
///
/// 修改即时生效（AppShell 直接消费 `AppSettings.shellLayout`）并落库。
class ShellLayoutSection extends ConsumerWidget {
  const ShellLayoutSection({super.key});

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
