import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/version.dart';
import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import '../widgets/license_viewer.dart';

/// 关于设置域
///
/// 数据库句柄由 `ref.watch(appDatabaseProvider)` 现取（P0-6）。
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final db = ref.watch(appDatabaseProvider).maybeValue;
    final rows = <(String, String)>[
      ('软件版本号', 'V${BuildInfo.appVersion}'),
      ('数据库版本号', 'user_version = ${db?.userVersion ?? '-'}'),
      ('SQLite 版本号', BuildInfo.sqliteVersion),
      ('Flutter 版本号', BuildInfo.flutterVersion),
      ('Dart 运行时', BuildInfo.dartVersion),
      ('原生基线版本号', BuildInfo.nativeVersion),
      ('操作系统', BuildInfo.osVersion),
    ];
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '关于',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              HubChip(
                label: db?.fts5Available == true ? 'FTS5 可用' : 'FTS5 不可用',
                selected: true,
                color: db?.fts5Available == true ? t.ok : t.warn,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: t.bg1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.border),
            ),
            child: Column(
              children: <Widget>[
                for (var i = 0; i < rows.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, color: t.border),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 132,
                          child: Text(
                            rows[i].$1,
                            style: TextStyle(color: t.textDim, fontSize: 13.5),
                          ),
                        ),
                        Expanded(
                          child: SelectableText(
                            rows[i].$2,
                            style: TextStyle(
                              color: t.textHi,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          // ★ 素材署名：位置刻意排在免责声明之前（不必滚到底才看到）。
          // HarmonyOS Sans 许可 §2.1「prominent notice」要求显著声明，
          // 文案**不得改写、不得加版本号**（许可协议本身不含版本号，
          // 自行补版本号属于虚构信息）。
          // 提示音 4.0 起已换成 CC0 素材（原 HarmonyOS tones 无独立许可，
          // 属发版风险），署名义务随之消失，但「素材来源」仍需如实列出。
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.bg1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '开源与素材许可',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '本软件使用了 HarmonyOS Sans 字体'
                  '（HarmonyOS 是华为技术有限公司的商标）。',
                  style: TextStyle(color: t.text, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 6),
                Text(
                  '界面图标来自 Fluent UI System Icons（Microsoft，MIT）；'
                  '提示音来自 Interface Sounds（Kenney，CC0 1.0）。',
                  style: TextStyle(color: t.text, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    GhostButton(
                      label: '《HarmonyOS Sans SC 字体许可协议》全文',
                      icon: Icons.description_outlined,
                      onPressed: () => showLicenseSheet(
                        context,
                        title: 'HarmonyOS Sans SC 字体许可协议',
                        assetPath: 'assets/fonts/HarmonyOS_Sans_SC_LICENSE.txt',
                      ),
                    ),
                    GhostButton(
                      label: '《Fluent UI System Icons 许可（MIT）》全文',
                      icon: Icons.description_outlined,
                      onPressed: () => showLicenseSheet(
                        context,
                        title: 'Fluent UI System Icons 许可（MIT）',
                        assetPath: 'assets/icons/LICENSE.txt',
                      ),
                    ),
                    GhostButton(
                      label: '《提示音许可说明（CC0）》',
                      icon: Icons.description_outlined,
                      onPressed: () => showLicenseSheet(
                        context,
                        title: '提示音许可说明（CC0）',
                        assetPath: 'assets/sounds/LICENSE-NOTICE.txt',
                      ),
                    ),
                    GhostButton(
                      label: '《CC0 1.0 Universal 法律文本》',
                      icon: Icons.description_outlined,
                      onPressed: () => showLicenseSheet(
                        context,
                        title: 'CC0 1.0 Universal 法律文本',
                        assetPath: 'assets/sounds/CC0-1.0-legalcode.txt',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.bg1,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.border),
            ),
            child: Text(
              '免责声明：本工具仅索引公开元数据，不下载/缓存/分发任何文件内容；'
              '仅在115网盘内使用，转载/分享请自行确认版权合规。',
              style: TextStyle(color: t.textDim, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}
