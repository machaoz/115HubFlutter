import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 提示音设置域（4.0 High-2）
///
/// 只放开**用户真的会改**的两项：总开关与音量。
/// （音效文件本身、单个事件绑哪个音这类属于产品默认值，不进设置页 ——
///   一旦放开就会变成没人动的死选项。）
///
/// 数据依赖只有 `appSettingsProvider`，不收构造参数，可被注册表任意摆放。
class SoundSection extends ConsumerWidget {
  const SoundSection({super.key});

  /// 音量百分比步长；滑到 0 等同静音但保留开关语义（关掉开关才彻底不播）
  static const int _divisions = 20;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);

    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '提示音',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '任务完成 / 导入完成 / 操作失败等节点播放短提示音；素材为 CC0 授权，'
            '许可全文见「关于」。',
            style: TextStyle(color: t.textDim, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('播放提示音', style: TextStyle(color: t.text)),
                    Text(
                      '关闭后所有提示音静默，任务状态仅靠界面反馈',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: s.soundEnabled,
                activeThumbColor: t.accent,
                onChanged: (v) => notifier.patchSound(enabled: v),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Text('音量', style: TextStyle(color: t.text)),
              const SizedBox(width: 10),
              Expanded(
                child: Slider(
                  value: s.soundVolume,
                  min: 0,
                  max: 1,
                  divisions: _divisions,
                  activeColor: t.accent,
                  onChanged: s.soundEnabled
                      ? (v) => notifier.patchSound(volume: v)
                      // 开关关闭时禁滑：否则会留下「调了却听不见」的假反馈
                      : null,
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${(s.soundVolume * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: s.soundEnabled ? t.text : t.textDisabled,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
