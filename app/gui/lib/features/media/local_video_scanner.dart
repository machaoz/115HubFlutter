import 'dart:io';

import '../../core/media/media_title_parser.dart';

/// 本地视频文件扫描（**零依赖纯 Dart**，与 `core/media/media_title_parser.dart` 同层）。
///
/// 【为什么扫描而不是「选文件」】
/// 引入 `file_picker` 会给本工程新增一个跨平台插件依赖，按 ADR-0001 的红线要求
/// 需重新走一遍 native-assets 钩子核查，且本项目 Windows-only 并不需要它带来的
/// 平台适配面。B1-S1 的目标是「跑通播放链路」，扫描目录已足够达成目标，
/// 交互上的「浏览选文件」留到有明确决策后再补不影响此处逻辑。
///
/// 默认只取一层（不去递归全盘）；需要多级时显式传 `recursive: true`。
/// 真正的大库索引走原生 hub_media_scan（见 ADR-0002）。
abstract final class LocalVideoScanner {
  /// 需要识别的视频扩展名（小写、排序后）。
  ///
  /// 【单一来源】M 批次复审发现这里曾是 10 项子集，与 native C++ 侧 19 项
  /// 不一致——切扫描后端会改变结果。现统一引用 core 层 [kVideoExtensions]
  /// （与 media_scan_gateway 的 Dart 回退、C++ hub_media_scan 同一口径），
  /// 三处共用一张表，改扩展名只动 media_title_parser.dart 一处。
  static final List<String> extensions = kVideoExtensions.toList()..sort();

  /// 扫描 [dir] 下的视频文件，按文件名排序；目录不存在或无权限返回空列表。
  ///
  /// [max] 是硬上限，防止把几万条目的目录一次性灌进 UI。
  ///
  /// [recursive] 为真时按层序向下遍历，最多 [maxDepth] 层；跳过以 `.` 开头的目录、
  /// `$RECYCLE.BIN`、`System Volume Information`（与原生 hub_media_scan 同规则，
  /// 保证 native 与 Dart 两条路出来的结果形状一致）。
  /// 默认 false —— 老调用点（`media_page` 等）的语义保持不变。
  static List<LocalVideoFile> scan(
    String dir, {
    int max = 500,
    bool recursive = false,
    int maxDepth = 8,
  }) {
    final List<LocalVideoFile> out = <LocalVideoFile>[];
    final Directory d = Directory(dir);
    if (!d.existsSync()) return out;
    try {
      if (!recursive) {
        _collectFiles(dir, 1, max, out);
      } else {
        // 层序遍历（BFS）：先浅后深，命中 max 时优先保留浅层条目 —— 用户的直觉是
        // 「根目录下的一定在」，深层目录被截掉反而符合预期。
        final List<_ScanLevel> queue = <_ScanLevel>[_ScanLevel(dir, 0)];
        while (queue.isNotEmpty) {
          final _ScanLevel level = queue.removeAt(0);
          _collectFiles(level.path, level.depth + 1, max - out.length, out);
          if (out.length >= max) break;
          if (level.depth + 1 >= maxDepth) continue;
          queue.addAll(_subDirectories(level.path, level.depth + 1));
        }
      }
    } on FileSystemException {
      // 无权限 / 路径异常一律当"没有"，不向上抛:
      // UI 上是"这个目录扫不到"，而不是把整页刷成错误态。
      return out;
    }
    out.sort((LocalVideoFile a, LocalVideoFile b) {
      final int byName = a.name.compareTo(b.name);
      return byName != 0 ? byName : a.path.compareTo(b.path);
    });
    return out;
  }

  /// 收一层目录下的视频文件（[budget] 是本轮还能再收多少条）
  static void _collectFiles(
    String dir,
    int depth,
    int budget,
    List<LocalVideoFile> out,
  ) {
    final List<FileSystemEntity> entities;
    try {
      entities = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      return; // 这一层扫不动就跳过，不让整次扫描失败
    }
    int added = 0;
    for (final FileSystemEntity e in entities) {
      if (added >= budget) break;
      if (e is! File) continue; // 目录、链接都不是 File，天然被排除
      if (!_isVideo(e.path)) continue;
      int size = 0;
      int mtimeMs = 0;
      try {
        final FileStat st = e.statSync();
        size = st.size;
        mtimeMs = st.modified.millisecondsSinceEpoch;
      } on FileSystemException {
        // 拿不到属性也要收录：文件存在但打不开属性，给 0 而不是丢条目
      }
      out.add(
        LocalVideoFile(
          path: e.path,
          name: _nameOf(e.path),
          sizeBytes: size,
          mtimeMs: mtimeMs,
          depth: depth,
        ),
      );
      added++;
    }
  }

  /// 子目录（已按规则过滤掉隐藏目录与两个 Windows 系统目录）
  static List<_ScanLevel> _subDirectories(String dir, int depth) {
    final List<_ScanLevel> res = <_ScanLevel>[];
    final List<FileSystemEntity> entities;
    try {
      entities = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      return res; // 同上：无权限的目录直接跳过
    }
    for (final FileSystemEntity e in entities) {
      if (e is! Directory) continue;
      if (_skipDirectory(_nameOf(e.path))) continue;
      res.add(_ScanLevel(e.path, depth));
    }
    return res;
  }

  /// 与 C++ 侧 skip_dir_name 保持一致：隐藏目录 + 两个 Windows 系统目录。
  /// 前者是用户自己藏的，后两个要么扫不动（访问被拒）、要么全是回收站垃圾。
  static bool _skipDirectory(String name) {
    if (name.isEmpty || name.startsWith('.')) return true;
    if (name == r'$RECYCLE.BIN') return true;
    if (name == 'System Volume Information') return true;
    return false;
  }

  /// 常见的视频起始目录：优先用户 Videos，缺失时回落到 UserProfile
  static String defaultDirectory() {
    final String? profile = Platform.environment['USERPROFILE'];
    if (profile == null || profile.isEmpty) return Directory.current.path;
    final Directory videos = Directory(
      '$profile${Platform.pathSeparator}Videos',
    );
    if (videos.existsSync()) return videos.path;
    return profile;
  }

  static bool _isVideo(String path) {
    final int dot = path.lastIndexOf('.');
    if (dot <= 0 || dot == path.length - 1) return false;
    return extensions.contains(path.substring(dot + 1).toLowerCase());
  }

  static String _nameOf(String path) {
    final int sep = path.lastIndexOf(Platform.pathSeparator);
    return sep < 0 ? path : path.substring(sep + 1);
  }
}

/// BFS 队列里的一层：目录路径 + 该目录自身的深度（扫描根算 0）
class _ScanLevel {
  const _ScanLevel(this.path, this.depth);
  final String path;
  final int depth;
}

/// 一个待播放的本地视频文件。
class LocalVideoFile {
  const LocalVideoFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    this.mtimeMs = 0,
    this.depth = 1,
  });

  /// 绝对磁盘路径（尚未转成 `file://` URI）
  final String path;

  /// 文件名（含扩展名）
  final String name;

  final int sizeBytes;

  /// 最后修改时间（毫秒）。取不到时为 0 —— 0 表示「未知」，不要拿它当 1970 年排序
  final int mtimeMs;

  /// 相对扫描根目录的层级：根目录的直接子项为 1（非递归扫描时恒为 1）
  final int depth;

  /// media_kit 期望的 URI 形态。Windows 绝对路径需转成 `file:///C:/...`。
  ///
  /// 直接把 `C:\xxx` 喂给 mpv 会被当成相对 Playable 解析失败。
  String get uri => Uri.file(path).toString();
}
