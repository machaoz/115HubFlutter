import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

/// 启动流程（《概要设计》§6.4）：
/// 单实例锁 → 打开 hub.db → 迁移 → 读设置 → 主题 → 托盘/窗口装配 → 后台暖机
/// 冷启动目标 ≤2s 出窗口：数据库打开放在 FutureProvider，窗口先出再由流式
/// 状态填充，避免 io 阻塞导致白屏。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // media_kit 初始化：加载 libmpv 动态库。**必须在任何 Player 创建之前**，
  // 且必须在 runApp 之前同步完成 —— 否则首个 Player 会抛"未初始化"。
  // Windows 下 libmpv 由 media_kit_libs_windows_video 随包分发，
  // NativeLibrary.path 自动解析，无需指定 libmpv 参数。
  // 选型依据与依赖红线核查见 docs/ADR-0001-视频播放内核选型.md。
  MediaKit.ensureInitialized();

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
