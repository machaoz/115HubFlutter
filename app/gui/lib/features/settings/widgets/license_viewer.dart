import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 许可全文查看弹窗
///
/// 【为什么是本地 asset 而不是外部 URL】
/// 许可 §2.4 要求「任何副本中保留版权声明与协议全文」。外链会失效，
/// 一旦失效该条款即不成立；随包 asset 离线可用，且版本与安装包强绑定。
///
/// 【红线】只做展示，不落临时文件、不上报、不修改原文一个字符。
Future<void> showLicenseSheet(
  BuildContext context, {
  required String title,
  required String assetPath,
}) async {
  final String text;
  try {
    text = await rootBundle.loadString(assetPath);
  } catch (e) {
    if (!context.mounted) return;
    // 资源缺失不应让「关于」页崩掉，但要如实告诉用户
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.t.surface1,
        title: Text(title, style: TextStyle(color: ctx.t.textHi)),
        content: Text(
          '许可全文读取失败：$e\n\n请确认安装包包含 $assetPath',
          style: TextStyle(color: ctx.t.text),
        ),
        actions: <Widget>[
          AccentButton(label: '关闭', onPressed: () => Navigator.of(ctx).pop()),
        ],
      ),
    );
    return;
  }
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final t = ctx.t;
      return AlertDialog(
        backgroundColor: t.surface1,
        title: Text(title, style: TextStyle(color: t.textHi)),
        content: SizedBox(
          width: 720,
          height: 440,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: TextStyle(
                color: t.text,
                fontSize: 12.5,
                fontFamily: 'Consolas',
                height: 1.45,
              ),
            ),
          ),
        ),
        actions: <Widget>[
          AccentButton(label: '关闭', onPressed: () => Navigator.of(ctx).pop()),
        ],
      );
    },
  );
}
