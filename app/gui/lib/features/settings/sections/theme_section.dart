import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/settings.dart';
import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 主题模式：预设主题 / 自定义
enum _ThemeMode { preset, custom }

/// 主题设置域
///
/// 多主题：先选「预设主题 / 自定义」模式，再展开对应细节
/// （此前一次铺开全部预设卡，入口太重；预设改由紧凑下拉选择）
///
/// 数据依赖只有 `appSettingsProvider`，不接收构造参数 —— 这是注册表
/// 能任意摆放本分区的前提（详见 `registry.dart`）。
class ThemeSection extends ConsumerWidget {
  const ThemeSection({super.key});

  /// 自定义主色候选（与预设主色互补，避免用户选到极难读的颜色）
  static const List<int> swatches = <int>[
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
                for (final c in swatches)
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
          const SizedBox(height: 14),
          Divider(height: 1, color: t.border),
          const SizedBox(height: 12),
          Text(
            '图标风格',
            style: TextStyle(
              color: t.textHi,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '作用于导航栏这类同时有「描边 / 填充」图标的位置；'
            '「跟随选中」是未选中描边、选中填充。',
            style: TextStyle(color: t.textDim, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          HubSegmented<AppIconStyle>(
            label: '图标风格',
            items: const <(AppIconStyle, String)>[
              (AppIconStyle.auto, '跟随选中'),
              (AppIconStyle.outline, '始终描边'),
              (AppIconStyle.filled, '始终填充'),
            ],
            value: AppIconStyle.parse(s.iconStyle),
            onChanged: (v) => notifier.patchIconStyle(v),
          ),
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
