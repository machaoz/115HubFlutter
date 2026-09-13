import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

/// 启动流程（《概要设计》§6.4）：
/// 单实例锁 → 打开 hub.db → 迁移 → 读设置 → 主题 → 托盘/窗口装配 → 后台暖机
/// 冷启动目标 ≤2s 出窗口：数据库打开放在 FutureProvider，窗口先出再由流式
/// 状态填充，避免 io 阻塞导致白屏。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(960, 640),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: Magnetic115HubApp()));
}
