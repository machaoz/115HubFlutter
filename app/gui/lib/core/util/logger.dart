import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 日志级别（数值越大越严重）
enum LogLevel {
  debug(0),
  info(1),
  warn(2),
  error(3);

  const LogLevel(this.value);
  final int value;
}

/// 落盘日志（轮转），规格见《概要设计》§4.1：
/// - 位置 **安装目录/.log/hub.log**（不可写时回退 %APPDATA%\Magnetic115Hub\logs）
/// - 单文件 >1MB 轮转，保留 3 个历史
/// - debug 构建默认 debug 级，release 默认 info 级
/// - **红线：永不落 Cookie / 凭证**（调用方负责脱敏，本类不做任何网络数据记录）
class HubLogger {
  HubLogger._();

  static final HubLogger instance = HubLogger._();
  static const _maxBytes = 1024 * 1024;
  static const _keepCount = 3;

  IOSink? _sink;
  File? _current;
  bool _ready = false;
  LogLevel _minLevel = LogLevel.info;

  bool get ready => _ready;
  LogLevel get minLevel => _minLevel;
  String get filePath => _current?.path ?? p.join(HubPaths.logsDir, 'hub.log');

  /// [minLevel] 留空时按构建模式推导：debug(dart VM assert 开启) → debug 级
  void init({LogLevel? minLevel}) {
    _minLevel =
        minLevel ??
        (() {
          var isDebug = false;
          assert(() {
            isDebug = true;
            return true;
          }());
          return isDebug ? LogLevel.debug : LogLevel.info;
        }());
    if (_ready) {
      i('日志级别调整为 ${_minLevel.name}');
      return;
    }
    try {
      HubPaths.ensureDirs();
      _current = File(p.join(HubPaths.logsDir, 'hub.log'));
      _rotateIfNeeded();
      _sink = _current!.openWrite(mode: FileMode.append);
      _ready = true;
      i('=== 日志开始（${HubPaths.logsDir}）===');
    } catch (_) {
      _ready = false; // 日志失败不能拖垮应用
    }
  }

  void _rotateIfNeeded() {
    final f = _current!;
    if (!f.existsSync() || f.lengthSync() < _maxBytes) return;
    for (var i = _keepCount; i >= 1; i--) {
      final src = File(
        p.join(HubPaths.logsDir, i == 1 ? 'hub.log' : 'hub.$i.log'),
      );
      final dst = File(p.join(HubPaths.logsDir, 'hub.${i + 1}.log'));
      if (i == _keepCount) {
        if (dst.existsSync()) dst.deleteSync();
      }
      if (src.existsSync()) src.renameSync(dst.path);
    }
  }

  void _write(LogLevel level, String message, Object? error) {
    if (level.value < _minLevel.value) return;
    final line =
        '[${DateTime.now().toIso8601String()}] [${level.name.toUpperCase()}] '
        '$message${error != null ? ' | $error' : ''}';
    _sink?.writeln(line);
  }

  static void d(String m) => instance._write(LogLevel.debug, m, null);
  static void i(String m) => instance._write(LogLevel.info, m, null);
  static void w(String m, [Object? e]) => instance._write(LogLevel.warn, m, e);
  static void e(String m, [Object? e]) => instance._write(LogLevel.error, m, e);

  static Future<void> flush() async => instance._sink?.flush();

  /// 导出最近若干行，供「设置 - 日志」查看
  static Future<List<String>> tail({int lines = 200}) async {
    try {
      final f = File(instance.filePath);
      if (!f.existsSync()) return const [];
      final content = await f.readAsString();
      final all = const LineSplitter().convert(content);
      return all.length <= lines ? all : all.sublist(all.length - lines);
    } catch (_) {
      return const [];
    }
  }
}
