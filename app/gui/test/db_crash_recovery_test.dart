import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:magnetic115hub/core/db/hub_database.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

/// 崩溃后启动失败回归测试。
///
/// 真实故障：`SqliteException(1546): disk I/O error`，
/// Causing statement: `PRAGMA journal_mode=WAL;`。
/// 根因是进程崩溃后残留的 `-wal` / `-shm` 让 SQLite 拒绝打开，
/// 而当时 `PRAGMA journal_mode=WAL` 裸调用，异常直接冒到 UI，
/// 表现为「启动失败」死胡同。
///
/// 真实 IOERR 依赖 mmap 与进程时序，无法稳定复现；
/// 因此这里通过替换 `openConnection` 精确注入失败点，
/// 断言「隔离 -shm → 重试成功」这条恢复路径。
void main() {
  late Directory tmp;
  late sq.Database Function(String path) realOpen;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hub_crash_');
    realOpen = HubDatabase.openConnection;
    // 建一个真实可用的库，作为"恢复后应该拿到的东西"
    final seed = realOpen('${tmp.path}/hub.db');
    seed.execute('CREATE TABLE t(id INTEGER PRIMARY KEY);');
    seed.execute('INSERT INTO t VALUES (1);');
    seed.close();
  });

  tearDown(() {
    HubDatabase.openConnection = realOpen;
    HubDatabase.quarantineDir = () => '${tmp.path}/quarantine';
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发句柄未释放，忽略
    }
  });

  test('正常库首次即打开成功，不产生任何隔离动作', () {
    HubDatabase.quarantineDir = () => '${tmp.path}/quarantine';
    final db = HubDatabase.openSyncForTest('${tmp.path}/hub.db');
    expect(db.getRow('SELECT count(*) c FROM t')['c'], 1);
    expect(Directory('${tmp.path}/quarantine').existsSync(), isFalse);
    db.close();
  });

  test('崩溃残留 -shm 导致打开失败时，隔离后能自愈', () {
    HubDatabase.quarantineDir = () => '${tmp.path}/quarantine';
    final shm = File('${tmp.path}/hub.db-shm')
      ..writeAsBytesSync(List<int>.filled(32768, 0));
    final wal = File('${tmp.path}/hub.db-wal')
      ..writeAsBytesSync(List<int>.filled(8, 0));

    var calls = 0;
    HubDatabase.openConnection = (path) {
      calls++;
      // 第一次因 shm 残留失败（模拟 1546），隔离后成功
      if (calls == 1) {
        throw sq.SqliteException(
          extendedResultCode: 1546,
          message: 'disk I/O error',
          causingStatement: 'PRAGMA journal_mode=WAL;',
        );
      }
      return realOpen(path);
    };

    final db = HubDatabase.openSyncForTest('${tmp.path}/hub.db');

    expect(calls, 2, reason: '应重试一次');
    // 关键断言：数据没丢
    expect(db.getRow('SELECT count(*) c FROM t')['c'], 1);
    // shm 被移走，wal 被保留（wal 里有已提交事务，不能丢）
    expect(shm.existsSync(), isFalse);
    expect(wal.existsSync(), isTrue);
    expect(
      Directory('${tmp.path}/quarantine')
          .listSync()
          .whereType<File>()
          .any((f) => f.path.contains('crash-shm')),
      isTrue,
      reason: '应留档而不是删除',
    );
    db.close();
  });

  test('-shm 隔离后仍失败则升级隔离 -wal', () {
    HubDatabase.quarantineDir = () => '${tmp.path}/quarantine';
    File('${tmp.path}/hub.db-shm').writeAsBytesSync(List<int>.filled(8, 0));
    File('${tmp.path}/hub.db-wal').writeAsBytesSync(List<int>.filled(8, 0));

    var calls = 0;
    HubDatabase.openConnection = (path) {
      calls++;
      if (calls <= 2) {
        throw sq.SqliteException(
          extendedResultCode: 1546,
          message: 'disk I/O error',
        );
      }
      return realOpen(path);
    };

    final db = HubDatabase.openSyncForTest('${tmp.path}/hub.db');

    expect(calls, 3);
    expect(db.getRow('SELECT count(*) c FROM t')['c'], 1);
    final q = Directory('${tmp.path}/quarantine').listSync().whereType<File>();
    expect(q.any((f) => f.path.contains('crash-shm')), isTrue);
    expect(q.any((f) => f.path.contains('crash-wal')), isTrue);
    db.close();
  });

  test('无残留可清时，抛出的错误是 openFailed 而非裸异常', () {
    HubDatabase.quarantineDir = () => '${tmp.path}/quarantine';
    HubDatabase.openConnection = (path) {
      throw sq.SqliteException(
        extendedResultCode: 1546,
        message: 'disk I/O error',
      );
    };

    expect(
      () => HubDatabase.openSyncForTest('${tmp.path}/hub.db'),
      throwsA(
        isA<HubDbException>().having(
          (e) => e.code,
          'code',
          HubDbError.openFailed,
        ),
      ),
    );
  });

  test('journal_mode 切 WAL 失败时降级继续，不阻断启动', () {
    // 真实场景：库文件被别的进程/句柄独占时 WAL 切换会失败。
    // 断言重点是「不抛错、连接照常可用」—— WAL 只是性能优化，不是正确性要求。
    HubDatabase.openConnection = (path) {
      final db = realOpen(path);
      db.execute('PRAGMA locking_mode=EXCLUSIVE;');
      return db;
    };
    final db = HubDatabase.openSyncForTest('${tmp.path}/hub.db');
    expect(db.getRow('SELECT count(*) c FROM t')['c'], 1);
    db.close();
  });

  test('备份校验：可打开的库通过，坏文件被拒', () {
    final good = File('${tmp.path}/good.db');
    realOpen(good.path).close();
    expect(HubDatabase.verifyBackup(good), isTrue);

    final bad = File('${tmp.path}/bad.db')
      ..writeAsStringSync('this is definitely not sqlite');
    expect(HubDatabase.verifyBackup(bad), isFalse);
  });
}
