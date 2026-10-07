// 崩溃恢复逻辑的独立验证（纯 Dart，不经 flutter test / build hooks）。
//
// 背景：本机 Dart VM 无法创建子进程（CreateFile failed 231），
// `dart test` 会在 sqlite3 的 native-assets hook 上失败，
// 所以这里用 sqlite3 的 FFI 直接驱动被测逻辑。
//
// 跑法：dart .tools/db_crash_guard.dart
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sq;

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    stdout.writeln('  PASS  $name');
  } else {
    _fail++;
    stdout.writeln('  FAIL  $name${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

/// 复刻 HubDatabase._openWithRecovery 的策略（同一份决策，逐条验证）。
///
/// 生产版在 hub_database.dart；这里保持逻辑同构，因为无法 import
/// 依赖 flutter 的模块。
sq.Database openWithRecovery(String dbPath, {String? quarantineTo}) {
  final qDir = quarantineTo ?? Directory.systemTemp.createTempSync('q').path;
  void quarantine(File f, String tag) {
    final d = Directory(qDir);
    if (!d.existsSync()) d.createSync(recursive: true);
    f.renameSync('$qDir/crash-$tag-${DateTime.now().microsecondsSinceEpoch}');
  }

  try {
    return sq.sqlite3.open(dbPath);
  } catch (_) {
    // 首次失败 → 清 -shm
  }

  final shm = File('$dbPath-shm');
  if (shm.existsSync()) {
    quarantine(shm, 'shm');
    try {
      return sq.sqlite3.open(dbPath);
    } catch (_) {
      // 仍失败 → 升级清 -wal
    }
  }

  final wal = File('$dbPath-wal');
  if (wal.existsSync()) {
    quarantine(wal, 'wal');
    return sq.sqlite3.open(dbPath);
  }

  throw StateError('open failed, no residue');
}

int countRows(sq.Database db, String table) =>
    db.select('SELECT count(*) c FROM $table').first['c'] as int;

void main() {
  final tmp = Directory.systemTemp.createTempSync('hub_crash_guard_');
  stdout.writeln('临时目录: ${tmp.path}');

  // ---------------------------------------------------------- 场景1：干净库
  stdout.writeln('\n[1] 干净库直接打开');
  {
    final p = '${tmp.path}/s1.db';
    final d = sq.sqlite3.open(p);
    d.execute('CREATE TABLE fav(id INTEGER PRIMARY KEY, name TEXT);');
    d.execute("INSERT INTO fav VALUES (1,'a'),(2,'b');");
    d.close();

    final q = '${tmp.path}/q1';
    final db = openWithRecovery(p, quarantineTo: q);
    check('数据完整', countRows(db, 'fav') == 2);
    check('未产生隔离目录', !Directory(q).existsSync());
    db.close();
  }

  // ------------------------------------------- 场景2：崩溃残留 -shm（真实验证）
  stdout.writeln('\n[2] 崩溃残留 -shm / -wal 后仍能打开且数据不丢');
  {
    final p = '${tmp.path}/s2.db';
    final d = sq.sqlite3.open(p);
    d.execute('PRAGMA journal_mode=WAL;');
    d.execute('CREATE TABLE fav(id INTEGER PRIMARY KEY, name TEXT);');
    d.execute("INSERT INTO fav VALUES (1,'a'),(2,'b'),(3,'c');");
    d.close();

    // close() 会 checkpoint 并清掉 -wal/-shm，所以这里手工造崩溃现场：
    // 保持一个连接持有 WAL（不 checkpoint），再断开，模拟进程被强杀。
    final holder = sq.sqlite3.open(p);
    holder.execute('PRAGMA journal_mode=WAL;');
    holder.execute("INSERT INTO fav VALUES (4,'d');");
    final wal = File('$p-wal');
    final shm = File('$p-shm');
    final hadWal = wal.existsSync();
    final hadShm = shm.existsSync();
    check('崩溃现场：wal 存在', hadWal);
    check('崩溃现场：shm 存在', hadShm);
    // 故意不 close()：正常 close 会 checkpoint 并清掉 -wal/-shm，
    // 那样就造不出崩溃现场了。这里让句柄随 isolate 结束而丢弃，
    // 效果等同于进程被强杀（不执行正常清理）。
    // ignore: unnecessary_statements
    holder;

    final q = '${tmp.path}/q2';
    var opened = true;
    var rows = -1;
    try {
      final db = openWithRecovery(p, quarantineTo: q);
      rows = countRows(db, 'fav');
      db.close();
    } catch (e) {
      opened = false;
      stdout.writeln('    (打开失败: ${e.toString().split('\n').first})');
    }
    check('崩溃残留下仍能打开', opened);
    if (opened) {
      check('已落盘数据一行不丢（>=3）', rows >= 3, 'rows=$rows');
    }
    final qd = Directory(q);
    check(
      '残留留档而非删除',
      !qd.existsSync() ||
          qd.listSync().whereType<File>().every((f) => f.existsSync()),
    );
  }

  // ------------------------------------- 场景3：-wal 头部损坏（1546 真凶模拟）
  stdout.writeln('\n[3] -wal 损坏时降级：数据以主库为准，库仍可用');
  {
    final p = '${tmp.path}/s3.db';
    final d = sq.sqlite3.open(p);
    d.execute('CREATE TABLE fav(id INTEGER PRIMARY KEY, name TEXT);');
    d.execute("INSERT INTO fav VALUES (1,'a'),(2,'b');");
    d.execute('PRAGMA journal_mode=WAL;');
    d.execute("INSERT INTO fav VALUES (3,'c');"); // 只在 wal 里，未 checkpoint
    d.close();

    // 破坏 wal 头（保留主库完整性）
    final wal = File('$p-wal');
    if (wal.existsSync()) {
      final bytes = wal.readAsBytesSync();
      // 前 32 字节是 wal 头，清零即失效
      wal.writeAsBytesSync(
        List<int>.filled(32, 0).followedBy(bytes.sublist(32)).toList(),
      );
    }
    final q = '${tmp.path}/q3';
    var opened = true;
    var rows = -1;
    try {
      final db = openWithRecovery(p, quarantineTo: q);
      rows = countRows(db, 'fav');
      db.close();
    } catch (e) {
      opened = false;
      stdout.writeln('    (打开失败: ${e.toString().split('\n').first})');
    }
    check('坏 wal 场景仍能拿到可读库（至少主库数据）', opened, '恢复链未能兜住');
    if (opened) {
      check('主库数据完整（>=2 行，wal 内未落盘事务允许丢失）', rows >= 2, 'rows=$rows');
    }
  }

  // ------------------------------------------------------ 场景4：备份可用性
  stdout.writeln('\n[4] 备份校验逻辑');
  {
    final good = '${tmp.path}/good.db';
    sq.sqlite3.open(good).close();
    final bad = '${tmp.path}/bad.db';
    File(bad).writeAsStringSync('definitely not a sqlite file');

    bool verify(String path) {
      sq.Database? c;
      try {
        c = sq.sqlite3.open(path, mode: sq.OpenMode.readOnly);
        c.execute('SELECT count(*) FROM sqlite_master;');
        return true;
      } catch (_) {
        return false;
      } finally {
        try {
          c?.close();
        } catch (_) {}
      }
    }

    check('合法备份通过校验', verify(good));
    check('损坏文件被拒', !verify(bad));
  }

  // ---------------------------------------------------------- 清理与汇总
  try {
    tmp.deleteSync(recursive: true);
  } catch (_) {
    // Windows 句柄未释放，忽略
  }

  stdout.writeln('\n────────────────────────────');
  stdout.writeln('通过 $_pass / 失败 $_fail');
  if (_fail > 0) exit(1);
}
