// media_scan_gateway.dart —— 媒体目录扫描的唯一入口（ADR-0002，v2.3 会话化）
//
// 【为什么要有这一层】
// 扫描是 IO 密集活，且 native 可能因 DLL 缺失/版本不符而不可用。网关把三件事
// 收敛到一个 Future 里：
//   1. 优先走 native（hub_scan_* 会话式扫描，后台线程 + 进度/暂停/取消），
//      **解析跑在 Isolate 里**，不占 UI isolate；
//   2. native 任何异常 → 记一条 warn → 静默降级 Dart 回退，绝不向上抛；
//   3. 用 [MediaScanResult.backend] 明说是 'native' 还是 'dart'，UI 才能如实展示，
//      而不是拿回退结果冒充原生扫描。
//
// 【v2.3：扫描与展示彻底解耦】
//   * 会话式 [startMediaScan]：进度流 + 暂停/恢复/取消，UI 随时可看可停；
//   * 扫描成功结束的那一刻，结果由 [MediaIndexStore] 原子写入索引 JSON ——
//     「第一次探查后重启不重复探查」由网关保证，调用方无需配合；
//   * 页面展示一律走 MediaIndexStore.load() 读索引，不关心索引怎么来的。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../native/hub_native_bindings.dart';
import '../util/logger.dart';
import 'media_index_store.dart';
import 'media_title_parser.dart';

/// 扫描结果的一条记录
class MediaScanEntry {
  const MediaScanEntry({
    required this.path,
    required this.name,
    required this.sizeBytes,
    this.mtimeMs = 0,
    this.depth = 1,
  });

  /// 绝对路径（native 返回正斜杠；Dart 回退按平台分隔符）
  final String path;

  /// 文件名（含扩展名）
  final String name;

  final int sizeBytes;

  /// 最后修改时间（**毫秒**）。native 侧给的是秒，这里统一 ×1000。
  /// 取不到时为 0 —— 0 是「未知」而不是「1970 年」，调用方不要拿它排序。
  final int mtimeMs;

  /// 相对扫描根目录的层级：根目录的直接子项为 1
  final int depth;

  /// 从 native JSON 的一项解析。任何字段缺失都给安全默认值，
  /// 不因一条脏记录让整次扫描失败。
  static MediaScanEntry fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) {
      return const MediaScanEntry(path: '', name: '', sizeBytes: 0);
    }
    final path = raw['path']?.toString() ?? '';
    return MediaScanEntry(
      path: path,
      name: raw['name']?.toString() ?? _nameOf(path),
      sizeBytes: _asInt(raw['size']),
      mtimeMs: _asInt(raw['mtime']) * 1000,
      depth: _asInt(raw['depth'], fallback: 1),
    );
  }

  /// 序列化为索引 JSON 的一项（mtime 落盘为秒，与 native 输出口径一致）
  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'name': name,
    'size': sizeBytes,
    'mtime': mtimeMs ~/ 1000,
    'depth': depth,
  };

  @override
  String toString() => 'MediaScanEntry($name, ${sizeBytes}B, depth=$depth)';
}

/// 一次扫描的结果。[backend] 用于 UI 如实标注能力来源。
class MediaScanResult {
  const MediaScanResult({required this.entries, required this.backend});

  final List<MediaScanEntry> entries;

  /// 'native' = 原生 hub_media_scan；'dart' = Dart 回退
  final String backend;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;
  int get length => entries.length;
}

// ==================================================================
// 会话式扫描（进度可取、可暂停/恢复/取消）
//
// 一段式调用是「发起→阻塞→拿全量」，大目录一扫十几秒 UI 只能干等。会话把
// 扫描搬进后台线程（native）或长驻 isolate（Dart 回退），调用方随时可看进度、
// 可暂停、可取消 —— 这也是媒体页进度条/暂停按钮的数据来源。
// ==================================================================

/// 扫描进度（native 每 150ms / Dart 回退每处理完若干目录上报一次）
class MediaScanProgress {
  const MediaScanProgress({required this.state, required this.files});

  /// running / paused / done / cancelled / error
  final String state;

  /// 已发现的视频文件数
  final int files;

  bool get isTerminal =>
      state == 'done' || state == 'cancelled' || state == 'error';
}

/// 一次可控扫描的句柄。[result] 在扫描成功或取消时完成（取消=空结果），
/// 失败时以异常完成。
class MediaScanHandle {
  const MediaScanHandle({
    required this.result,
    required this.onProgress,
    required this.pause,
    required this.resume,
    required this.cancel,
  });

  final Future<MediaScanResult> result;
  final Stream<MediaScanProgress> onProgress;
  final void Function() pause;
  final void Function() resume;
  final void Function() cancel;
}

/// 一段式兼容入口（旧调用方语义：await 拿全量）。内部走会话式扫描。
Future<MediaScanResult> scanMediaDirectory(
  String root, {
  int maxDepth = 8,
  int maxFiles = 2000,
}) => startMediaScan(root, maxDepth: maxDepth, maxFiles: maxFiles).result;

/// 启动会话式扫描。native 优先（后台线程+轮询），DLL 缺失/启动失败静默降级
/// Dart 回退（长驻 isolate，能力对齐：进度/暂停/恢复/取消）。
MediaScanHandle startMediaScan(
  String root, {
  int maxDepth = 8,
  int maxFiles = 2000,
}) {
  if (root.trim().isEmpty) {
    return _completedHandle(
      const MediaScanResult(entries: <MediaScanEntry>[], backend: 'dart'),
    );
  }
  if (hubNativeAvailable) {
    try {
      return _startNativeSession(
        root.trim(),
        maxDepth: maxDepth > 0 ? maxDepth : 8,
        maxFiles: maxFiles > 0 ? maxFiles : 2000,
      );
    } catch (e) {
      // 降级而不是失败：扫描能力缺失时应用仍要能用（只是慢一点）
      HubLogger.w('会话式原生扫描启动失败，降级 Dart 回退', e);
    }
  }
  return _startDartSession(
    root.trim(),
    maxDepth: maxDepth > 0 ? maxDepth : 8,
    maxFiles: maxFiles > 0 ? maxFiles : 2000,
  );
}

MediaScanHandle _completedHandle(MediaScanResult r) {
  return MediaScanHandle(
    result: Future<MediaScanResult>.value(r),
    onProgress: const Stream<MediaScanProgress>.empty(),
    pause: () {},
    resume: () {},
    cancel: () {},
  );
}

/// native 会话：FFI 轮询器。轮询在 UI isolate 上做（150ms 一次、纯内存 FFI
/// 调用 + 小 JSON 解析，不构成帧压力）；扫描本体在 native 后台线程。
MediaScanHandle _startNativeSession(
  String root, {
  required int maxDepth,
  required int maxFiles,
}) {
  final int sid = hubScanStart(root, maxDepth: maxDepth, maxFiles: maxFiles);
  final progress = StreamController<MediaScanProgress>.broadcast();
  final completer = Completer<MediaScanResult>();
  Timer? timer;

  void finish(FutureOr<MediaScanResult> r) {
    timer?.cancel();
    if (!completer.isCompleted) completer.complete(Future.sync(() => r));
    progress.close();
    try {
      hubScanClose(sid);
    } catch (_) {}
  }

  timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
    MediaScanProgress p;
    try {
      final Object? decoded = jsonDecode(hubScanPoll(sid));
      if (decoded is! Map<String, Object?>) return;
      p = MediaScanProgress(
        state: decoded['state']?.toString() ?? 'running',
        files: _asInt(decoded['files']),
      );
      if (!progress.isClosed) progress.add(p);
    } catch (e) {
      finish(Future<MediaScanResult>.error(e));
      return;
    }
    if (!p.isTerminal) return;

    // 终态：done 取结果并落盘；cancelled 视作空结果；error 上抛
    if (p.state == 'done') {
      finish(_finishNativeDone(sid, root));
    } else if (p.state == 'cancelled') {
      finish(
        const MediaScanResult(entries: <MediaScanEntry>[], backend: 'native'),
      );
    } else {
      finish(Future<MediaScanResult>.error(StateError('扫描失败：${p.state}')));
    }
  });

  return MediaScanHandle(
    result: completer.future,
    onProgress: progress.stream,
    pause: () {
      try {
        hubScanPause(sid);
      } catch (_) {}
    },
    resume: () {
      try {
        hubScanResume(sid);
      } catch (_) {}
    },
    cancel: () {
      try {
        hubScanCancel(sid);
      } catch (_) {}
    },
  );
}

/// done 终态 → 取结果 → 写索引（「第一次探查后重启不重复探查」的落点）。
/// 解析跑在 Isolate 内：大数组 JSON 解析不占 UI 帧。
Future<MediaScanResult> _finishNativeDone(int sid, String root) async {
  final entries = await Isolate.run(
    () => _parseEntries(hubScanResult(sid)),
    debugName: 'hub_scan_result',
  );
  MediaIndexStore.save(
    MediaIndex(
      root: root,
      backend: 'native',
      scannedAtMs: DateTime.now().millisecondsSinceEpoch,
      entries: entries,
    ),
  );
  return MediaScanResult(entries: entries, backend: 'native');
}

/// Dart 回退：长驻 isolate。BFS 每处理完一个目录让出一个事件循环拍节，
/// 命令（pause/resume/cancel）与进度消息借此流动 —— 纯同步循环会让消息
/// 永远排队，暂停就失效了。
MediaScanHandle _startDartSession(
  String root, {
  required int maxDepth,
  required int maxFiles,
}) {
  final progress = StreamController<MediaScanProgress>.broadcast();
  final completer = Completer<MediaScanResult>();
  SendPort? cmdPort;
  final ready = ReceivePort();
  final results = ReceivePort();

  void cleanup() {
    ready.close();
    results.close();
    progress.close();
  }

  void finishWith(MediaScanResult r) {
    if (!completer.isCompleted) completer.complete(r);
    cleanup();
  }

  ready.listen((Object? msg) {
    if (msg is SendPort) cmdPort = msg;
  });
  results.listen(
    (Object? msg) {
      if (msg is! Map<String, Object?>) return;
      switch (msg['type']) {
        case 'progress':
          if (!progress.isClosed) {
            progress.add(
              MediaScanProgress(
                state: msg['state']?.toString() ?? 'running',
                files: _asInt(msg['files']),
              ),
            );
          }
        case 'done':
          final entries = <MediaScanEntry>[
            for (final Object? e
                in (msg['entries'] as List<Object?>? ?? const []))
              MediaScanEntry.fromJson(e),
          ];
          MediaIndexStore.save(
            MediaIndex(
              root: root,
              backend: 'dart',
              scannedAtMs: DateTime.now().millisecondsSinceEpoch,
              entries: entries,
            ),
          );
          finishWith(MediaScanResult(entries: entries, backend: 'dart'));
        case 'cancelled':
          finishWith(
            const MediaScanResult(entries: <MediaScanEntry>[], backend: 'dart'),
          );
        case 'error':
          if (!completer.isCompleted) {
            completer.complete(
              Future<MediaScanResult>.error(
                StateError(msg['message']?.toString() ?? '扫描失败'),
              ),
            );
          }
          cleanup();
      }
    },
    onDone: () {
      // isolate 意外退出：按空结果收场，不让 UI 永远转圈
      finishWith(
        const MediaScanResult(entries: <MediaScanEntry>[], backend: 'dart'),
      );
    },
  );

  Isolate.spawn(
    _dartScanIsolate,
    _DartScanArgs(root, maxDepth, maxFiles, ready.sendPort, results.sendPort),
    debugName: 'hub_media_scan_session',
  ).then<void>(
    (Isolate _) {},
    onError: (Object e, StackTrace _) {
      HubLogger.w('Dart 扫描 isolate 启动失败', e);
      if (!completer.isCompleted) {
        completer.complete(Future<MediaScanResult>.error(e));
      }
      cleanup();
    },
  );

  void send(String cmd) {
    final SendPort? p = cmdPort;
    try {
      p?.send(cmd);
    } catch (_) {}
  }

  return MediaScanHandle(
    result: completer.future,
    onProgress: progress.stream,
    pause: () => send('pause'),
    resume: () => send('resume'),
    cancel: () => send('cancel'),
  );
}

class _DartScanArgs {
  const _DartScanArgs(
    this.root,
    this.maxDepth,
    this.maxFiles,
    this.readyPort,
    this.outPort,
  );
  final String root;
  final int maxDepth;
  final int maxFiles;
  final SendPort readyPort;
  final SendPort outPort;
}

/// isolate 主函数：命令口 + 进度口 + 可暂停/取消的 BFS。
/// 规则与 native 引擎一致（跳过隐藏目录 / $RECYCLE.BIN / System Volume
/// Information，深度/条数上限），保证两条路结果形状相同。
Future<void> _dartScanIsolate(_DartScanArgs args) async {
  final cmd = ReceivePort();
  args.readyPort.send(cmd.sendPort);

  bool paused = false;
  bool cancelled = false;
  cmd.listen((Object? m) {
    switch (m) {
      case 'pause':
        paused = true;
      case 'resume':
        paused = false;
      case 'cancel':
        cancelled = true;
    }
  });

  try {
    final entries = <MediaScanEntry>[];
    final queue = <_ScanLevel>[_ScanLevel(args.root, 0)];
    var tick = 0;
    while (queue.isNotEmpty) {
      if (cancelled) {
        args.outPort.send(<String, Object?>{'type': 'cancelled'});
        return;
      }
      // 暂停：事件循环里打转，命令口保持畅通
      while (paused && !cancelled) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      if (cancelled) {
        args.outPort.send(<String, Object?>{'type': 'cancelled'});
        return;
      }
      if (entries.length >= args.maxFiles) break;

      final _ScanLevel level = queue.removeAt(0);
      _collectFiles(
        level.path,
        level.depth + 1,
        args.maxFiles - entries.length,
        entries,
      );
      if (level.depth + 1 < args.maxDepth) {
        queue.addAll(_subDirectories(level.path, level.depth + 1));
      }
      // 每个目录让出一拍 + 定期上报进度（消息借此送达）
      await Future<void>.delayed(Duration.zero);
      if (++tick % 4 == 0) {
        args.outPort.send(<String, Object?>{
          'type': 'progress',
          'state': paused ? 'paused' : 'running',
          'files': entries.length,
        });
      }
    }
    entries.sort((MediaScanEntry a, MediaScanEntry b) {
      final byName = a.name.compareTo(b.name);
      return byName != 0 ? byName : a.path.compareTo(b.path);
    });
    args.outPort.send(<String, Object?>{
      'type': 'progress',
      'state': 'running',
      'files': entries.length,
    });
    args.outPort.send(<String, Object?>{
      'type': 'done',
      'entries': <Object?>[for (final MediaScanEntry e in entries) e.toJson()],
    });
  } catch (e) {
    args.outPort.send(<String, Object?>{
      'type': 'error',
      'message': e.toString(),
    });
  } finally {
    cmd.close();
  }
}

/// 解析 native 返回的条目 JSON（跑在 Isolate 内，大数组解析不占 UI 帧）
List<MediaScanEntry> _parseEntries(String json) {
  if (json.isEmpty) return const <MediaScanEntry>[];
  final Object? decoded = jsonDecode(json);
  if (decoded is! List<Object?>) return const <MediaScanEntry>[];
  return decoded
      .map(MediaScanEntry.fromJson)
      .where((MediaScanEntry e) => e.path.isNotEmpty)
      .toList(growable: false);
}

// ------------------------------------------------------------------
// Dart 回退的目录遍历原语（isolate 内使用）
// ------------------------------------------------------------------

class _ScanLevel {
  const _ScanLevel(this.path, this.depth);
  final String path;
  final int depth;
}

void _collectFiles(
  String dirPath,
  int depth,
  int budget,
  List<MediaScanEntry> out,
) {
  if (budget <= 0) return;
  final List<FileSystemEntity> entities;
  try {
    entities = Directory(dirPath).listSync(followLinks: false);
  } on FileSystemException {
    return; // 无权限 / 路径异常：这一支跳过，不算整次失败
  }
  var added = 0;
  for (final FileSystemEntity e in entities) {
    if (added >= budget) break;
    // followLinks:false 时符号链接是 Link 而不是 File，天然被排除
    if (e is! File) continue;
    if (!_isVideo(e.path)) continue;
    int size = 0;
    int mtimeMs = 0;
    try {
      final st = e.statSync();
      size = st.size;
      mtimeMs = st.modified.millisecondsSinceEpoch;
    } on FileSystemException {
      // 取不到属性也要收录：文件存在但打不开属性，给 0 而不是丢条目
    }
    out.add(
      MediaScanEntry(
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

List<_ScanLevel> _subDirectories(String dirPath, int depth) {
  final res = <_ScanLevel>[];
  final List<FileSystemEntity> entities;
  try {
    entities = Directory(dirPath).listSync(followLinks: false);
  } on FileSystemException {
    return res;
  }
  for (final FileSystemEntity e in entities) {
    if (e is! Directory) continue; // 链接不是 Directory，不跟随
    final name = _nameOf(e.path);
    if (_skipDirectory(name)) continue;
    res.add(_ScanLevel(e.path, depth));
  }
  return res;
}

/// 与 C++ 侧 skip_dir_name 保持一致：隐藏目录 + 两个 Windows 系统目录。
/// 这两个目录要么扫不动（访问被拒），要么全是回收站垃圾，扫出来只污染媒体库。
bool _skipDirectory(String name) {
  if (name.isEmpty || name.startsWith('.')) return true;
  if (name == r'$RECYCLE.BIN') return true;
  if (name == 'System Volume Information') return true;
  return false;
}

/// 视频扩展名判定直接引用 [kVideoExtensions]（media_title_parser.dart）——
/// M 批次复审裁决：白名单必须单一来源，与 C++ hub_media_scan、
/// LocalVideoScanner 三处共用一张表，改扩展名只动 media_title_parser.dart。
bool _isVideo(String path) {
  final dot = path.lastIndexOf('.');
  if (dot <= 0 || dot == path.length - 1) return false;
  return kVideoExtensions.contains(path.substring(dot + 1).toLowerCase());
}

String _nameOf(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  return sep < 0 ? path : path.substring(sep + 1);
}

int _asInt(Object? v, {int fallback = 0}) => switch (v) {
  final int n => n,
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? fallback,
  _ => fallback,
};
