import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 字体设置域（4.0 High-2）
///
/// 数据依赖只有 `appSettingsProvider`，**不收任何构造参数**，
/// 因此可以被注册表任意摆放，也不必在装配主体里出现。
class FontSection extends ConsumerWidget {
  const FontSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    final current = AppFontFamily.parse(s.fontFamily);

    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '字体',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '默认使用随包内置的 HarmonyOS Sans SC；切到「系统默认」则交给 Windows 字体回退链。',
            style: TextStyle(color: t.textDim, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          HubSegmented<AppFontFamily>(
            label: '字体',
            items: const <(AppFontFamily, String)>[
              (AppFontFamily.harmonyOS, 'HarmonyOS Sans SC'),
              (AppFontFamily.system, '系统默认'),
            ],
            value: current,
            onChanged: (v) => ref
                .read(appSettingsProvider.notifier)
                .update(s.copyWith(fontFamily: v.name)),
          ),
        ],
      ),
    );
  }
}
