import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 首页推荐设置域
///
/// 4.0 High-2 会把数据源从豆瓣切到 TMDB（本分区是设置页里最先被重写的域），
/// 因此即便只有 70 行也保持独立文件，不与邻居合并。
class RecommendSection extends ConsumerWidget {
  const RecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '首页推荐',
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
                child: Text('推荐总开关', style: TextStyle(color: t.text)),
              ),
              Switch(
                value: s.recommend.enabled,
                activeThumbColor: t.accent,
                onChanged: (v) => ref
                    .read(appSettingsProvider.notifier)
                    .patchRecommend(s.recommend.copyWith(enabled: v)),
              ),
            ],
          ),
          // 【V1.1.0 预留】首页数据源可切换
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('数据源', style: TextStyle(color: t.text)),
                    Text(
                      'V1.1.0 将支持 TMDB / 自定义源',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              HubSegmented<String>(
                label: '首页数据源',
                items: const <(String, String)>[
                  ('douban', '豆瓣'),
                  ('tmdb', 'TMDB'),
                ],
                value: s.recommend.sourceId,
                onChanged: (v) {
                  if (v == 'tmdb') {
                    showHubToast(context, 'TMDB 源将在 V1.1.0 提供（当前仍走豆瓣）');
                    return;
                  }
                  ref
                      .read(appSettingsProvider.notifier)
                      .patchRecommend(s.recommend.copyWith(sourceId: v));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
