import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqlite3/sqlite3.dart' as sq;

import '../util/app_paths.dart';
import '../util/logger.dart';

/// 当前端认知的最高 schema 版本（= 迁移 SQL 文件数）
/// 【红线】与 Electron 版保持一致；新增结构从 v8 起追加文件，禁止改写 v1–v7。
const int kSchemaVersion = 7;

/// 打开/迁移失败的错误码（对应《概要设计》§7「明确错误码与恢复指引」）
enum HubDbError { openFailed, migrationFailed, newerSchema, writeDisabled }

class HubDbException implements Exception {
  const HubDbException(this.code, this.message, {this.cause});
  final HubDbError code;
  final String message;
  final Object? cause;

  /// 面向用户的可读文案（UI 只展示这里的内容）
  String get userMessage => switch (code) {
    HubDbError.openFailed => '无法打开数据文件，请检查是否被占用或磁盘权限不足。',
    HubDbError.migrationFailed => '数据升级或迁移完整性校验失败：$message',
    HubDbError.newerSchema => '检测到更高版本的数据文件，本程序已切换为只读以免回写损坏数据，请升级到最新版。',
    HubDbError.writeDisabled => '当前为只读模式（检测到更高版本数据），无法执行写入。',
  };

  @override
  String toString() => 'HubDbException(${code.name}): $message';
}

/// 单一 SQLite 连接封装。
/// 数据兼容红线（继承《盘点与规划》1.5）：
///  1. 迁移只追加不改历史 —— SQL 文本来自 assets/migrations/vN.sql（双端单一来源）
///  2. FTS 删除一律普通 DELETE ... WHERE rowid=?
///  3. LIKE 值必须 escapeLike()
///  4. 打开到更高版本库时只读拒绝写
class HubDatabase {
  HubDatabase._(this._db, {required this.path, required this.readOnly});

  sq.Database _db;
  final String path;

  /// 检测到 user_version > kSchemaVersion 时为 true（只读保护）
  bool readOnly;

  bool fts5Available = false;
  bool fts5TrigramAvailable = false;

  sq.Database get handle => _db;
  int get userVersion => _db.userVersion;

  /// LIKE 转义（% _ \ 三类通配必须转义，否则检索结果错乱且可能被注入异常模式）
  static String escapeLike(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  // ---------------------------------------------------------------- 打开/迁移

  static Future<HubDatabase> open({
    String? path,
    Map<int, String>? sqlOverride,
  }) async {
    final dbPath = path ?? HubPaths.dbPath;
    HubPaths.ensureDirs();
    final File file = File(dbPath);
    if (!file.existsSync()) {
      await file.parent.create(recursive: true);
    }

    sq.Database raw;
    try {
      raw = sq.sqlite3.open(dbPath);
    } catch (e) {
      HubLogger.e('open hub.db failed', e);
      throw HubDbException(HubDbError.openFailed, e.toString(), cause: e);
    }

    raw.execute('PRAGMA journal_mode=WAL;');
    raw.execute('PRAGMA foreign_keys=ON;');

    final db = HubDatabase._(raw, path: dbPath, readOnly: false);

    if (raw.userVersion > kSchemaVersion) {
      // 防止旧程序回写新库
      db.readOnly = true;
      HubLogger.w(
        'hub.db user_version=${raw.userVersion} > $kSchemaVersion，切换只读',
      );
    } else {
      try {
        await db.migrate(sqlOverride: sqlOverride);
      } catch (_) {
        raw.close();
        rethrow;
      }
    }
    db.probeCapabilities();
    return db;
  }

  /// 按 user_version 逐条补跑缺失迁移；已跑过的版本绝不重复执行。
  Future<void> migrate({Map<int, String>? sqlOverride}) async {
    if (readOnly) {
      throw const HubDbException(HubDbError.writeDisabled, 'readOnly');
    }
    final current = _db.userVersion;
    final sqls = sqlOverride ?? await loadMigrationSql();
    if (sqlOverride == null) {
      await verifyMigrationChecksums(sqls);
    }
    if (current >= kSchemaVersion) return;

    for (var v = current + 1; v <= kSchemaVersion; v++) {
      final sql = sqls[v];
      if (sql == null || sql.trim().isEmpty) {
        throw HubDbException(HubDbError.migrationFailed, '缺失迁移文件 v$v.sql');
      }
      try {
        _db.execute(sql);
        _db.execute('PRAGMA user_version = $v;');
        HubLogger.i('migration v$v applied');
      } catch (e) {
        HubLogger.e('migration v$v failed', e);
        throw HubDbException(HubDbError.migrationFailed, 'v$v: $e', cause: e);
      }
    }
  }

  /// 从 assets 加载全部迁移 SQL 文本（双端单一来源）
  static Future<Map<int, String>> loadMigrationSql() async {
    final out = <int, String>{};
    for (var v = 1; v <= kSchemaVersion; v++) {
      out[v] = await rootBundle.loadString('assets/migrations/v$v.sql');
    }
    return out;
  }

  /// 校验迁移文本指纹，防止双端文本漂移（《下步开发计划》R3 的阻断门禁）。
  ///
  /// [manifestText] 仅供纯函数测试注入；生产路径始终读取 assets 中的清单。
  static Future<void> verifyMigrationChecksums(
    Map<int, String> sqls, {
    String? manifestText,
  }) async {
    try {
      final text =
          manifestText ??
          await rootBundle.loadString('assets/migrations/checksums.json');
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('checksums.json 根节点必须是对象');
      }

      for (final entry in sqls.entries) {
        final key = 'v${entry.key}';
        final expected = decoded[key]?.toString().trim() ?? '';
        if (expected.isEmpty) {
          throw HubDbException(
            HubDbError.migrationFailed,
            '迁移 ${entry.key} 缺少指纹清单',
          );
        }
        final actual = sha256.convert(utf8.encode(entry.value)).toString();
        if (actual != expected) {
          throw HubDbException(
            HubDbError.migrationFailed,
            '迁移 ${entry.key} 指纹不匹配，已阻止启动以避免双端结构漂移',
          );
        }
      }
      HubLogger.i('migration checksums verified (${sqls.length})');
    } on HubDbException {
      rethrow;
    } catch (e) {
      throw HubDbException(HubDbError.migrationFailed, '无法校验迁移指纹：$e', cause: e);
    }
  }

  // ---------------------------------------------------------------- PoC-1 自检

  /// FTS5 能力自检：决定是否需要《下步开发计划》PoC-1 的 C++ 兜底路径。
  /// 返回是否“FTS5 + trigram 分词”均可用。
  bool probeCapabilities() {
    // 基础 FTS5
    try {
      _db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS _fts_probe USING fts5(x)',
      );
      _db.execute('DROP TABLE IF EXISTS _fts_probe');
      fts5Available = true;
    } catch (e) {
      fts5Available = false;
      HubLogger.w('FTS5 不可用', e);
    }
    // trigram 分词（收藏全文检索依赖，需 SQLite >= 3.34）
    if (fts5Available) {
      try {
        _db.execute(
          "CREATE VIRTUAL TABLE IF NOT EXISTS _fts_probe2 USING fts5(x, tokenize='trigram')",
        );
        _db.execute('DROP TABLE IF EXISTS _fts_probe2');
        fts5TrigramAvailable = true;
      } catch (e) {
        fts5TrigramAvailable = false;
        HubLogger.w('FTS5 trigram 不可用（<3 字检索将全部退化为 LIKE）', e);
      }
    }
    HubLogger.i(
      'sqlite=${sq.sqlite3.version.libVersion} '
      'fts5=$fts5Available trigram=$fts5TrigramAvailable user_version=$userVersion',
    );
    return fts5Available && fts5TrigramAvailable;
  }

  // ---------------------------------------------------------------- 备份/维护

  /// VACUUM INTO 快照。注意：调用前必须已关闭连接（WAL checkpoint），
  /// 因此本方法會先 close 再重开（对齐 Electron 版 restore 前 closeDb 的口径）。
  Future<String> backup({String? target}) async {
    HubPaths.ensureDirs();
    final to =
        target ??
        pj(
          HubPaths.backupsDir,
          'hub-${DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.db',
        );
    close();
    try {
      _rawOpenAndVacuum(path, to);
    } finally {
      await reopen();
    }
    return to;
  }

  void _rawOpenAndVacuum(String from, String to) {
    final conn = sq.sqlite3.open(from);
    try {
      conn.execute("VACUUM INTO '${to.replaceAll("'", "''")}';");
    } finally {
      conn.close();
    }
  }

  Future<void> reopen() async {
    try {
      _db.close();
    } catch (_) {
      // 已关闭的情况忽略
    }
    final fresh = sq.sqlite3.open(path);
    fresh.execute('PRAGMA journal_mode=WAL;');
    fresh.execute('PRAGMA foreign_keys=ON;');
    _db = fresh;
    probeCapabilities();
  }

  void close() {
    try {
      _db.close();
    } catch (_) {
      // ignore
    }
  }
}

// -------- 轻量工具：避免额外依赖 path_provider 带来的平台分支复杂度
String pj(String a, String b) =>
    a.endsWith('\\') || a.endsWith('/') ? '$a$b' : '$a\\$b';
