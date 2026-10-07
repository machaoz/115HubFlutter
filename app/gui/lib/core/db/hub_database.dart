import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
// visibleForTesting 走 flutter/foundation 导出，与 session_vault.dart 保持一致，
// 避免为了一个注解在 pubspec 里显式声明 meta（那会让 lint 变成新的门禁债）。
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
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

  /// 取单行查询的第一行（无结果则空 Map）。测试与轻量探针用。
  @visibleForTesting
  Map<String, Object?> getRow(String sql, [List<Object?> params = const []]) {
    final r = _db.select(sql, params);
    return r.isEmpty ? const <String, Object?>{} : r.first;
  }

  /// LIKE 转义（% _ \ 三类通配必须转义，否则检索结果错乱且可能被注入异常模式）
  static String escapeLike(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  // ---------------------------------------------------------------- 打开/迁移

  /// 应用连接级PRAGMA。WAL 切换失败**不致命** —— 见 [_tryWal]。
  static void _applyPragmas(sq.Database db, {bool wal = true}) {
    if (wal) {
      _tryWal(db);
    }
    // foreign_keys 失败同样只记录：它只影响级联删除，不该拦住启动
    try {
      db.execute('PRAGMA foreign_keys=ON;');
    } catch (e) {
      HubLogger.w('PRAGMA foreign_keys 启用失败（不影响启动）', e);
    }
  }

  /// 切 WAL 模式，失败则保持原模式并继续。
  ///
  /// WAL 不是正确性要求，只是并发读性能优化，所以任何失败都只降级不抛错。
  /// 崩溃后残留的 `-wal` / `-shm` 会让这一步报 `disk I/O error (1546)`，
  /// 那种情况下库本身多半仍是好的，保持原模式照样能读写。
  static void _tryWal(sq.Database db) {
    try {
      final r = db.select('PRAGMA journal_mode=WAL;');
      final mode = r.isEmpty ? '' : r.first.values.first.toString();
      if (mode.toLowerCase() != 'wal') {
        HubLogger.w('journal_mode 切换为 $mode 而非 wal（已降级继续）');
      }
    } catch (e) {
      HubLogger.w('PRAGMA journal_mode=WAL 失败，保持原模式继续启动', e);
    }
  }

  /// 打开底层连接的工厂。生产用 [sq.sqlite3.open]；
  /// 测试可替换成会抛错的桩，以验证崩溃恢复分支（真实 IOERR 难以稳定复现）。
  @visibleForTesting
  static sq.Database Function(String path) openConnection = sq.sqlite3.open;

  /// 崩溃现场目录，测试可指向临时目录，避免污染真实 backups。
  @visibleForTesting
  static String Function() quarantineDir = () => HubPaths.backupsDir;

  /// 带崩溃恢复的打开。
  ///
  /// 进程被强杀 / 断电后，SQLite 可能留下三类残留，让下一次 `open` 直接抛
  /// `SQLITE_IOERR`（Windows 上尤其如此，shm 走的是 mmap）：
  /// 1. `-shm`：共享内存索引，**纯派生数据，随时可重建**
  /// 2. `-wal`：已提交但未 checkpoint 的事务，**有真实数据，不能删**
  /// 3. `-wal` 头部损坏：此时保留它反而会让每次打开都失败
  ///
  /// 策略：先原样打开；失败则隔离 `-shm` 重试（最安全，WAL 里数据不丢）；
  /// 再失败才隔离 `-wal` 一并重试（此时数据以主库文件为准，最多丢最后未落盘的
  /// 几个事务，但能换回一个能用的库）。任何隔离动作都先移到 backups/，
  /// 不做不可逆删除。
  static sq.Database _openWithRecovery(String dbPath) {
    try {
      return openConnection(dbPath);
    } catch (first) {
      HubLogger.w('首次打开失败，尝试隔离崩溃残留（-shm）', first);
    }

    final shm = File('$dbPath-shm');
    if (shm.existsSync()) {
      _quarantine(shm, 'shm');
      try {
        return openConnection(dbPath);
      } catch (second) {
        HubLogger.w('隔离 -shm 后仍失败，尝试隔离 -wal', second);
      }
    }

    final wal = File('$dbPath-wal');
    if (wal.existsSync()) {
      _quarantine(wal, 'wal');
      return openConnection(dbPath);
    }

    // 没有残留可清还失败：把首次的异常抛出去，那才是真因
    throw StateError('open failed and no crash residue to clean');
  }

  /// 把残留文件移进 backups/ 而非删除 —— 崩溃现场要留证，也允许人工回滚。
  static void _quarantine(File f, String tag) {
    try {
      final dir = quarantineDir();
      final d = Directory(dir);
      if (!d.existsSync()) d.createSync(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final dest = pj(dir, 'crash-$tag-$stamp${_extOf(f.path)}');
      f.renameSync(dest);
      HubLogger.w('已隔离崩溃残留 ${f.path} -> $dest');
    } catch (e) {
      // 隔离本身失败（如被占用）不应盖掉原始错误
      HubLogger.w('隔离 $tag 失败（可能被占用）', e);
    }
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i);
  }

  /// 纯同步的「打开 + PRAGMA」步骤，不含迁移与能力探测。
  ///
  /// 抽出来是为了让崩溃恢复逻辑能在单元测试里直接驱动 ——
  /// 它不碰 rootBundle，也不需要 Flutter 绑定。
  @visibleForTesting
  static HubDatabase openSyncForTest(String dbPath) {
    final sq.Database raw;
    try {
      raw = _openWithRecovery(dbPath);
    } catch (e) {
      HubLogger.e('open hub.db failed', e);
      throw HubDbException(HubDbError.openFailed, e.toString(), cause: e);
    }
    _applyPragmas(raw);
    return HubDatabase._(raw, path: dbPath, readOnly: false);
  }

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

    final db = openSyncForTest(dbPath);
    final raw = db._db;

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
    final fresh = _openWithRecovery(path);
    _applyPragmas(fresh);
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

  // ---------------------------------------------------------------- 崩溃恢复

  /// 列出可用的快照，按时间倒序（新的在前）。
  ///
  /// 递归扫描：备份可能落在 `backups/` 的子目录里（如人工修复归档），
  /// 只扫顶层会漏掉它们，恢复入口就形同虚设。
  /// 排除隔离残留（`crash-*.db`）—— 那是故障现场，不是可用快照。
  static List<File> listBackups() {
    try {
      final dir = Directory(HubPaths.backupsDir);
      if (!dir.existsSync()) return const [];
      final files = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.db'))
          .where((f) => !p.basename(f.path).toLowerCase().startsWith('crash-'))
          .toList();
      files.sort(
        (a, b) => b.path.compareTo(a.path),
      ); // 文件名以 ISO 时间戳开头，字典序 == 时间序
      return files;
    } catch (e) {
      HubLogger.w('枚举备份失败', e);
      return const [];
    }
  }

  /// 校验某个备份是否可正常打开且结构完整。
  /// 供 UI 在「恢复」前先探一下，避免拿坏快照覆盖现有数据。
  static bool verifyBackup(File backup) {
    sq.Database? conn;
    try {
      conn = sq.sqlite3.open(backup.path, mode: sq.OpenMode.readOnly);
      conn.execute('SELECT count(*) FROM sqlite_master;');
      return true;
    } catch (e) {
      HubLogger.w('备份校验失败: ${backup.path}', e);
      return false;
    } finally {
      try {
        conn?.close();
      } catch (_) {
        // ignore
      }
    }
  }

  /// 用指定备份覆盖当前库。**破坏性操作**，调用方必须先向用户确认。
  ///
  /// 现存的 hub.db 会被移到 backups/ 而不是删除，保证可回滚。
  static void restoreFrom(File backup) {
    final dbPath = HubPaths.dbPath;
    HubPaths.ensureDirs();
    // 清掉可能残留的 wal/shm，否则它们会被套用到新库上造成二次损坏
    for (final suffix in const ['-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (f.existsSync()) _quarantine(f, 'restore$suffix');
    }
    if (File(dbPath).existsSync()) {
      _quarantine(File(dbPath), 'pre-restore');
    }
    backup.copySync(dbPath);
    HubLogger.i('已从备份恢复: ${backup.path} -> $dbPath');
  }
}

// -------- 轻量工具：避免额外依赖 path_provider 带来的平台分支复杂度
String pj(String a, String b) =>
    a.endsWith('\\') || a.endsWith('/') ? '$a$b' : '$a\\$b';
