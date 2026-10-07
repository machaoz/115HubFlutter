import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/util/logger.dart';
import '../../ui/theme.dart';
import 'media_playback_error.dart';
import 'media_source.dart';

/// 单个视频画面 + 播放控制。
///
/// 【为什么由它独占 [Player] 生命周期】
/// ADR-0001 §4.3 定了「全 App 唯一 Player 单例」以避免多个解码器打架。
/// B1-S1 阶段先按「一个载入点一台 Engine」的最小形态实现：
/// [Player] 在 initState 里建、dispose 里销毁，Widget 卸载即释放，
/// 不做跨页缓存。**任何时刻树上只有一个本组件时自然满足单例约定**；
/// 将来要做多实例互斥，只需在外层加一层 Engine 持有者，此处不用改。
///
/// 【硬解】`VideoControllerConfiguration.hwdec` 留空 = 交给 libmpv 自动选择
/// （D3D11 优先，失败回落软解），这与 ADR-0001 §5「硬解失败自动回落软解」一致。
/// 刻意不写死具体 hwdec 值：不同显卡的可行取值不同，写死反而会在部分机器上黑屏。
class MediaPlayerView extends StatefulWidget {
  const MediaPlayerView({super.key, required this.source, this.onError});

  /// 播放源。**必须由 [MediaSource.media] 构造**，
  /// 且调用方负责售后不再持有它 —— 见 [MediaSource] 里的凭证红线。
  final Media source;

  /// 起播失败回调（文件不存在 / 编码不支持 / 解码器缺失）。
  ///
  /// 传出去的是**已归类**的诊断（见 [MediaPlaybackError]），不是原始异常字符串 ——
  /// 调用方直接拿去显示即可，不必自己再判一遍。
  final void Function(MediaPlaybackError error)? onError;

  @override
  State<MediaPlayerView> createState() => _MediaPlayerViewState();
}

class _MediaPlayerViewState extends State<MediaPlayerView> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<String>? _errorSub;
  MediaPlaybackError? _error;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    // open() 对「文件不存在」「编码不认」都只是抛一个泛化异常，解码器起不来更是
    // 只在 stream.error 里出声。两条路都要接，否则用户只会看到一片黑屏。
    _errorSub = _player.stream.error.listen(_onStreamError);
    _open(widget.source);
  }

  @override
  void didUpdateWidget(covariant MediaPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.uri != widget.source.uri) {
      _open(widget.source);
    }
  }

  void _onStreamError(String message) {
    HubLogger.w('media: player error stream: $message');
    _fail(classifyPlaybackError(message));
  }

  Future<void> _open(Media source) async {
    setState(() => _error = null);
    HubLogger.d('media: open ${MediaSource.describe(source)}');
    final bool exists = _existsLocally(source.uri);
    try {
      await _player.open(source, play: true);
    } catch (e) {
      // 只描述 scheme/host，不碰 httpHeaders（见 MediaSource 红线）
      HubLogger.w('media: open failed ${MediaSource.describe(source)}', e);
      _fail(classifyPlaybackError(e, fileExists: exists));
    }
  }

  void _fail(MediaPlaybackError err) {
    if (!mounted) return;
    setState(() => _error = err);
    widget.onError?.call(err);
  }

  /// 本地文件是否真实存在。
  ///
  /// 用于把「文件没了」与「格式不认」分开 —— mpv 对两者都可能只报
  /// "Failed to open"，不借助磁盘状态根本分不出来。
  /// 非 `file:` 源（将来的网盘直连）一律视为存在，不做无谓的磁盘探测。
  ///
  /// **坑**：`Media` 构造时会把 `file:///C:/x.mp4` 归一化回裸路径 `C:/x.mp4`
  /// （media_kit `media_native.dart` 的 `normalizeURI`，对齐 libmpv 内部口径）。
  /// 所以 `source.uri` 拿到的是裸路径而非 `file:` 串 —— 只认 `file:` 前缀会让
  /// 这个探测永远返回 true，「文件没了」就永远报成「格式不支持」。
  static bool _existsLocally(String uri) {
    final String lower = uri.toLowerCase();
    // 非本地源（将来的网盘直连）不做无谓的磁盘探测
    if (lower.startsWith('http:') || lower.startsWith('https:')) return true;
    try {
      final String path = lower.startsWith('file:')
          ? Uri.parse(uri).toFilePath()
          : uri;
      return File(path).existsSync();
    } catch (_) {
      return true;
    }
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    // media_kit 的 dispose 内部已 stop(notify:false)，无需先手动停；
    // 释放失败不能拖垮 UI 树卸载，故吞掉异常（Player 已无法恢复，无更好的处置）。
    _player.dispose().catchError((Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        // 播放态一律纯黑：letterbox（画面比例与容器不符时的留边）按行业惯例用黑底，
        // 用 bg0 会在浅色主题（bg0=浅灰/米白）下露出白边。
        // 错误态仍走主题底色 —— _buildError 用的是 textHi/textDim（浅色主题下近黑），
        // 若铺黑会直接糊成一片看不见。
        color: _error != null ? context.t.bg0 : _videoLetterboxBlack,
        child: _error != null ? _buildError() : _buildVideo(),
      ),
    );
  }

  /// 视频底色。见 build() 里的白边根因说明。
  static const Color _videoLetterboxBlack = Colors.black;

  Widget _buildVideo() {
    return Video(
      controller: _controller,
      // 控制条用 media_kit 自适应实现：ESC / F / 双击切全屏由它内建
      // （material_desktop.dart 的 keyboardShortcuts：escape→exitFullscreen、
      // keyF→toggleFullscreen，2.0.1 源码已核）。**不要**在外层再包一层
      // CallbackShortcuts 重复绑 ESC —— 冗余包装既多一层组件，也掩盖
      // 「快捷键由控制条主题负责」这一归属；将来若换自定义 controls 主题，
      // 记得在新主题的 keyboardShortcuts 里保留 escape 条目。
      // width/height 留 null：交给父布局约束，Video 自身按视频比例铺满
      fill: _videoLetterboxBlack,
      fit: BoxFit.contain,
      //
      // 【为什么要接这两个钩子】media_kit 的「全屏」是应用内行为：它往 rootNavigator
      // 推一条全屏路由来铺满 Flutter 视图（methods/fullscreen.dart 的 enterFullscreen），
      // **并不会动操作系统窗口** —— Windows 窗口依然是带边框的窗口模式，
      // 用户感知到的只是「画面变大了」，不是认知里的全屏。
      // 故在进入/退出时同步驱动 windowManager.setFullScreen，两者叠加才是「真全屏」。
      //
      // 退出路径不止一条：ESC、控制条按钮、以及返回键 pop（fullscreen.dart 里
      // FullscreenInheritedWidget 的 PopScope 会调 onExitFullscreen），最终都走到
      // onExitFullscreen —— 所以**两个钩子都必须接**，只接一个会出现
      // 「进了全屏退不出来」的窗口状态残留。
      onEnterFullscreen: () async => windowManager.setFullScreen(true),
      onExitFullscreen: () async => windowManager.setFullScreen(false),
    );
  }

  Widget _buildError() {
    final AppTokens t = context.t;
    final MediaPlaybackError err = _error!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, size: 40, color: t.danger),
            const SizedBox(height: 12),
            Text(
              err.headline,
              style: TextStyle(
                color: t.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              err.suggestion,
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textDim, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 10),
            // 原始信息照给用户：归不了类时不许替播放器编理由
            Text(
              err.detail,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textDim, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
