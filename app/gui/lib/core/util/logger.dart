import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 落盘日志（轮转），规格见《概要设计》§4.1：
/// - 位置 `%APPDATA%\Magnetic115Hub\logs\hub.log`
/// - 单文件 >1MB 轮转，保留 3 个历史
/// - **红线：永不落 Cookie / 凭证**（调用方负责脱敏，本类不做任何网络数据记录）
class HubLogger {
  HubLogger._();

  static final HubLogger instance = HubLogger._();
  static const _maxBytes = 1024 * 1024;
  static const _keepCount = 3;

  IOSink? _sink;
  File? _current;
  bool _ready = false;

  void init() {
    if (_ready) return;
    try {
      HubPaths.ensureDirs();
      _current = File(p.join(HubPaths.logsDir, 'hub.log'));
      _rotateIfNeeded();
      _sink = _current!.openWrite(mode: FileMode.append);
      _ready = true;
    } catch (_) {
      _ready = false; // 日志失败不能拖垮应用
    }
  }

  void _rotateIfNeeded() {
    final f = _current!;
    if (!f.existsSync() || f.lengthSync() < _maxBytes) return;
    for (var i = _keepCount; i >= 1; i--) {
      final src = File(p.join(HubPaths.logsDir, i == 1 ? 'hub.log' : 'hub.$i.log'));
      final dst = File(p.join(HubPaths.logsDir, 'hub.${i + 1}.log'));
      if (i == _keepCount) {
        if (dst.existsSync()) dst.deleteSync();
      }
      if (src.existsSync()) src.renameSync(dst.path);
    }
  }

  void _write(String level, String message, Object? error) {
    final line = '[${DateTime.now().toIso8601String()}] [$level] $message'
        '${error != null ? ' | $error' : ''}';
    _sink?.writeln(line);
  }

  static void d(String m) => instance._write('DEBUG', m, null);
  static void i(String m) => instance._write('INFO', m, null);
  static void w(String m, [Object? e]) => instance._write('WARN', m, e);
  static void e(String m, [Object? e]) => instance._write('ERROR', m, e);

  static Future<void> flush() async => instance._sink?.flush();

  /// 导出最近若干行，供「设置 - 日志」查看
  static Future<List<String>> tail({int lines = 200}) async {
    try {
      final f = File(p.join(HubPaths.logsDir, 'hub.log'));
      if (!f.existsSync()) return const [];
      final content = await f.readAsString();
      final all = const LineSplitter().convert(content);
      return all.length <= lines ? all : all.sublist(all.length - lines);
    } catch (_) {
      return const [];
    }
  }
}
