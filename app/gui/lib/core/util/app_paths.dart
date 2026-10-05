import 'dart:io';

import 'package:path/path.dart' as p;

/// 应用路径
///
/// 数据目录与 Electron 版严格一致：`%APPDATA%\Magnetic115Hub\`
/// （单文件 SQLite 库与备份落这里，保证双端可打开同一份数据）
///
/// 日志另有一套口子：**优先落「安装目录/.log」**——随包可携带，用户把整个安装
/// 目录打包发回来即可现场取证；只有安装目录不可写（如装在 Program Files 且无
/// 管理员权限）才回退 %APPDATA%。
class HubPaths {
  const HubPaths._();

  static String get dataDir {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      return p.join(appData, 'Magnetic115Hub');
    }
    final home = Platform.environment['USERPROFILE'] ?? '.';
    return p.join(home, 'AppData', 'Roaming', 'Magnetic115Hub');
  }

  /// 安装目录（exe 所在目录）。异常场景回退当前工作目录。
  static String get installDir {
    try {
      final exe = Platform.resolvedExecutable;
      if (exe.isNotEmpty) return p.dirname(exe);
    } catch (_) {
      // ignore：拿不到就用工作目录
    }
    return Directory.current.path;
  }

  /// 遗留兼容的旧 Electron userData 目录名（仅用于提示）
  static String get dbPath => p.join(dataDir, 'hub.db');

  /// AppData 下的日志兜底目录
  static String get appDataLogsDir => p.join(dataDir, 'logs');

  static String get backupsDir => p.join(dataDir, 'backups');

  /// 系统级加密凭证文件（DPAPI 密文，**不含任何明文**）
  static String get secretFilePath =>
      p.join(dataDir, 'credentials', 'pan115.bin');

  /// 日志目录（结果缓存，进程内只探测一次）
  static String get logsDir => _logsDir ??= _resolveLogsDir();
  static String? _logsDir;

  static String _resolveLogsDir() {
    final preferred = p.join(installDir, '.log');
    return _writableOrNull(preferred) ??
        _writableOrNull(appDataLogsDir) ??
        preferred;
  }

  /// 试探可写：能建目录且能在其中落临时文件才算可写
  static String? _writableOrNull(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      final probe = File(p.join(dir, '.hub_write_probe'));
      probe.writeAsStringSync('1');
      probe.deleteSync();
      return dir;
    } catch (_) {
      return null;
    }
  }

  static void ensureDirs() {
    for (final d in <String>[dataDir, logsDir, backupsDir]) {
      final dir = Directory(d);
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }
  }
}
