import 'dart:io';

import 'package:path/path.dart' as p;

/// 应用数据路径：与 Electron 版严格一致 —— `%APPDATA%\Magnetic115Hub\`
/// （单文件 SQLite 库、日志、备份都落这里，保证双端可打开同一份数据）
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

  /// 遗留兼容的旧 Electron userData 目录名（仅用于提示）
  static String get dbPath => p.join(dataDir, 'hub.db');
  static String get logsDir => p.join(dataDir, 'logs');
  static String get backupsDir => p.join(dataDir, 'backups');

  static void ensureDirs() {
    for (final d in <String>[dataDir, logsDir, backupsDir]) {
      final dir = Directory(d);
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }
  }
}
