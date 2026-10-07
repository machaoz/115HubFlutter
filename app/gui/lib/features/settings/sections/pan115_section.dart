import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/settings.dart';
import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 115 会话设置域（W1）：选择登录「绑定设备槽位」，避免与网页端登录互相挤下线
///
/// 【为什么不支持「未登录则隐藏」】
/// 本分区的核心控件是绑定设备槽位选择器，它的价值恰恰体现在**登录之前** ——
/// 让用户先把槽位选成小程序 / 电视端，免得一扫码就把浏览器网页端顶下线。
/// 未登录时隐藏等于逼用户先挤掉自己一次才能发现这个设置。
class Pan115Section extends ConsumerWidget {
  const Pan115Section({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(appSettingsProvider);
    final cfg = s.pan115;
    final app = pan115AppOf(cfg.loginApp);
    final ctl = ref.read(appSettingsProvider.notifier);

    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '115 会话',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '115 的登录会话按「设备槽位」区分：用「网页版」登录会把浏览器网页端顶下线。'
            '选一个你平时不占用的槽位（推荐小程序 / 电视端），即可与网页端同时在线、互不干扰。',
            style: TextStyle(color: t.textDim, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text('绑定设备', style: TextStyle(color: t.text)),
              ),
              HubDropdown<String>(
                label: '设备',
                minWidth: 220,
                items: kPan115Apps.map((a) => (a.id, a.label, true)).toList(),
                value: cfg.loginApp,
                onChanged: (v) {
                  ctl.patchPan115(cfg.copyWith(loginApp: v));
                  showHubToast(
                    context,
                    '下次扫码将绑定「${pan115AppOf(v).label.split('（').first}」',
                  );
                },
              ),
            ],
          ),
          if (app.conflicts) ...<Widget>[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.warn.withValues(alpha: 0.12),
                border: Border.all(color: t.warn.withValues(alpha: 0.45)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, size: 16, color: t.warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '当前槽位会挤掉你在用的那一端，建议换成小程序或电视端。',
                      style: TextStyle(color: t.warn, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 26),
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('轮询云端真实进度', style: TextStyle(color: t.text)),
                    Text(
                      '导入看板每 ${cfg.pollIntervalSeconds}s 拉一次 115 离线任务列表',
                      style: TextStyle(color: t.textDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: cfg.pollCloudProgress,
                activeThumbColor: t.accent,
                onChanged: (v) =>
                    ctl.patchPan115(cfg.copyWith(pollCloudProgress: v)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
