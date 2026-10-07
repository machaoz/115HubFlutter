// media_index_store.dart —— 媒体索引 JSON 的持久化（探查结果落盘、重启复用）
//
// 【为什么要有这一层】
// 文件探查是 IO 密集活，一次大目录扫描十几秒甚至更久。扫描产生的 JSON 索引
// 必须落盘：第一次探查之后，重启/重开页面直接读索引展示（秒开），**不再重扫**；
// 只有用户显式点「重新扫描」或索引文件不存在/损坏时才真正走扫描。
//
// 【与扫描的解耦】
// 视频列表只认本层产出的索引 JSON，不关心它怎么来的（native 会话扫描 /
// Dart 回退 / 上次启动落盘）。扫描器负责生成，本层负责存取，互不知晓实现。
//
// 【文件布局】
// %APPDATA%\Magnetic115Hub\media_index\local_<fnv1a64(root 规范化)>.json
// 每个根目录一个文件：多根互不覆盖；写失败不影响已有索引（临时文件+重命名）。
import 'dart:convert';
import 'dart:io';

import '../util/app_paths.dart';
import '../util/logger.dart';
import 'media_scan_gateway.dart';

/// 一份已落盘的媒体索引
class MediaIndex {
  const MediaIndex({
    required this.root,
    required this.backend,
    required this.scannedAtMs,
    required this.entries,
  });

  static const int kVersion = 2;

  /// 扫描根目录（原样保存，仅用于展示与校验，不参与文件名）
  final String root;

  /// 生成该索引的引擎：'native' / 'dart'（展示用「索引缓存」徽标时不区分）
  final String backend;

  /// 扫描完成时间（毫秒）
  final int scannedAtMs;

  final List<MediaScanEntry> entries;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': kVersion,
    'root': root,
    'backend': backend,
    'scannedAtMs': scannedAtMs,
    'files': <Object?>[for (final MediaScanEntry e in entries) e.toJson()],
  };

  /// 任何字段损坏都安全降级为 null，不抛异常 —— 索引坏了的最坏结果是重扫一次
  static MediaIndex? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    if (raw['version'] != kVersion) return null;
    final root = raw['root']?.toString() ?? '';
    if (root.isEmpty) return null;
    final files = raw['files'];
    if (files is! List<Object?>) return null;
    final entries = <MediaScanEntry>[];
    for (final Object? f in files) {
      final MediaScanEntry e = MediaScanEntry.fromJson(f);
      if (e.path.isNotEmpty) entries.add(e);
    }
    return MediaIndex(
      root: root,
      backend: raw['backend']?.toString() ?? '',
      scannedAtMs: _asInt(raw['scannedAtMs']),
      entries: entries,
    );
  }

  static int _asInt(Object? v) => switch (v) {
    final int n => n,
    final num n => n.toInt(),
    final String s => int.tryParse(s) ?? 0,
    _ => 0,
  };
}

/// FNV-1a 64：root 路径 → 稳定文件名片段（进程内无 crypto 依赖）
int _fnv1a64(String s) {
  int h = 0xcbf29ce484222325;
  for (final int c in s.codeUnits) {
    h ^= c;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h;
}

class MediaIndexStore {
  const MediaIndexStore._();

  /// 索引目录基路径（首次访问即创建；创建失败时文件操作会就近报错）
  static String _dirPath() => HubPaths.dataDir.isEmpty
      ? 'media_index'
      : '${HubPaths.dataDir}${Platform.pathSeparator}media_index';

  /// 规范化 root：正斜杠 + 小写盘符/路径 —— Windows 路径大小写不敏感，
  /// 'D:\Media' 与 'd:/media' 必须命中同一份索引
  static String normalizeRoot(String root) {
    var r = root.trim().replaceAll('\\', '/');
    if (r.length >= 2 && r[1] == ':') {
      r = '${r[0].toLowerCase()}${r.substring(1)}';
    }
    while (r.length > 3 && r.endsWith('/')) {
      r = r.substring(0, r.length - 1);
    }
    return r;
  }

  static String pathFor(String root) =>
      '${_dirPath()}${Platform.pathSeparator}local_'
      '${_fnv1a64(normalizeRoot(root)).toRadixString(16)}.json';

  /// 读索引；不存在/损坏/根对不上 → null（调用方据此决定是否扫描）
  static MediaIndex? load(String root) {
    final f = File(pathFor(root));
    if (!f.existsSync()) return null;
    try {
      final Object? decoded = jsonDecode(f.readAsStringSync());
      final MediaIndex? idx = MediaIndex.fromJson(decoded);
      if (idx == null) return null;
      // 根校验：防止哈希碰撞或手工挪文件把 A 目录的索引当成 B 的
      if (normalizeRoot(idx.root) != normalizeRoot(root)) return null;
      return idx;
    } catch (e) {
      HubLogger.w('媒体索引读取失败（将重新扫描）: ${f.path}', e);
      return null;
    }
  }

  /// 原子落盘：先写临时文件再重命名，中途失败不破坏既有索引
  static bool save(MediaIndex index) {
    try {
      final tmp = File('${pathFor(index.root)}.tmp');
      tmp.writeAsStringSync(jsonEncode(index.toJson()), flush: true);
      tmp.renameSync(pathFor(index.root));
      return true;
    } catch (e) {
      HubLogger.w('媒体索引写入失败', e);
      return false;
    }
  }

  /// 删除某根的索引（目录被移除/用户清数据时用；文件不存在静默）
  static void delete(String root) {
    final f = File(pathFor(root));
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (e) {
        HubLogger.w('媒体索引删除失败', e);
      }
    }
  }
}
