/// 播放失败的用户可见诊断。
///
/// 【为什么要单独一个纯 Dart 文件】
/// 播放失败的原因对开发者是日志、对用户必须是「一句话说清是哪种坏法」——
/// 文件读不到 / 格式不支持 / 解码器没起来，三类处置方式完全不同
/// （换文件 / 换片源 / 换显卡驱动或关硬解）。这个判定必须能被离线复跑，
/// 所以按 `core/db/shell_layout.dart` 的先例：**零依赖纯 Dart**，
/// 由 `.tools/media_local_check.dart` 直接 import 跑断言。
enum MediaPlaybackErrorKind {
  /// 文件不存在 / 不可读（路径错了、盘没了、被占用）
  unreadableFile,

  /// 容器或编码格式不支持
  unsupportedFormat,

  /// 解码器没能起来（硬解初始化失败 / 编解码器缺失）
  decoderFailure,

  /// 归不了类：把原始信息原样交给用户，不猜
  unknown,
}

/// 一次播放失败的诊断结果。
class MediaPlaybackError {
  const MediaPlaybackError({required this.kind, required this.detail});

  final MediaPlaybackErrorKind kind;

  /// 原始错误信息。**调用方必须先脱敏**（`Media.toString()` 会吐 header，
  /// 见 `MediaSource` 红线）—— 这里只做透传，不自行拼接 [Media]。
  final String detail;

  /// 一句话结论（给用户看的标题）
  String get headline => switch (kind) {
    MediaPlaybackErrorKind.unreadableFile => '文件读不到',
    MediaPlaybackErrorKind.unsupportedFormat => '格式不支持',
    MediaPlaybackErrorKind.decoderFailure => '解码器没起来',
    MediaPlaybackErrorKind.unknown => '播放失败',
  };

  /// 下一步该干什么（给用户看的建议）
  String get suggestion => switch (kind) {
    MediaPlaybackErrorKind.unreadableFile => '文件可能已被移动、删除，或所在磁盘不可访问。请重新扫描目录。',
    MediaPlaybackErrorKind.unsupportedFormat =>
      '这个容器/编码不在内置解码范围内，换一个文件或转成 H.264+AAC 的 MP4 再试。',
    MediaPlaybackErrorKind.decoderFailure =>
      '硬解初始化失败且未成功回落软解。请更新显卡驱动；仍不行就记录此信息反馈。',
    MediaPlaybackErrorKind.unknown => '下面是播放器给出的原始信息，可据此排查。',
  };
}

/// 把播放器的原始错误归类。
///
/// [fileExists] 由调用方（`MediaPlayerView`）在起播前用真实磁盘状态传入 ——
/// 比从错误文本里猜可靠得多：mpv 对「文件不存在」和「格式不认」都可能只说
/// "Failed to open"，仅靠文本分不开。
MediaPlaybackError classifyPlaybackError(
  Object? raw, {
  bool fileExists = true,
}) {
  final String msg = (raw?.toString() ?? '').toLowerCase();

  if (!fileExists) {
    return MediaPlaybackError(
      kind: MediaPlaybackErrorKind.unreadableFile,
      detail: _or(raw),
    );
  }
  if (_hits(msg, const <String>[
    'no such file',
    'not found',
    'permission denied',
    'access is denied',
    'cannot open',
    'failed to open',
  ])) {
    return MediaPlaybackError(
      kind: MediaPlaybackErrorKind.unreadableFile,
      detail: _or(raw),
    );
  }
  // 「解码器」要排在「格式」之前：mpv 的 "Failed to initialize a decoder"
  // 同时含 initialize 与 decoder，报成"格式不支持"会把用户带去转码，方向就错了。
  if (_hits(msg, const <String>[
    'decoder',
    'hwdec',
    'd3d11',
    'dxva',
    'cuda',
    'vaapi',
    'video output',
    'could not initialize',
  ])) {
    return MediaPlaybackError(
      kind: MediaPlaybackErrorKind.decoderFailure,
      detail: _or(raw),
    );
  }
  if (_hits(msg, const <String>[
    'unsupported',
    'unrecognized',
    'unrecognised',
    'unknown format',
    'no format',
    'failed to recognize',
    'codec not found',
    'cannot recognize',
  ])) {
    return MediaPlaybackError(
      kind: MediaPlaybackErrorKind.unsupportedFormat,
      detail: _or(raw),
    );
  }
  return MediaPlaybackError(
    kind: MediaPlaybackErrorKind.unknown,
    detail: _or(raw),
  );
}

bool _hits(String msg, List<String> keys) {
  for (final k in keys) {
    if (msg.contains(k)) return true;
  }
  return false;
}

String _or(Object? raw) {
  final String s = raw?.toString().trim() ?? '';
  return s.isEmpty ? '（播放器没有给出具体原因）' : s;
}
