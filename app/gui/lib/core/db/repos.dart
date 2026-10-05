import 'dart:convert';

import 'hub_database.dart';
import '../network/pan115_tasks.dart';
import '../util/logger.dart';
import '../../sources/source.dart';

/// 收藏仓库
/// 检索口径（严格对齐 Electron 版 favorites-repo.ts）：
/// - ≥3 字：FTS5 trigram MATCH **并集** LIKE
/// - <3 字：仅 LIKE（trigram 无法匹配短词）
/// - **删除一律普通 DELETE ... WHERE rowid=?**
class FavoritesRepo {
  FavoritesRepo(this._db);
  final HubDatabase _db;

  List<ResourceItem> list({String group = '', int limit = 500}) {
    final rows = group.isEmpty
        ? _db.handle.select(
            'SELECT item_json FROM favorites ORDER BY updated_at DESC LIMIT ?',
            <Object?>[limit],
          )
        : _db.handle.select(
            'SELECT item_json FROM favorites WHERE group_name=? ORDER BY updated_at DESC LIMIT ?',
            <Object?>[group, limit],
          );
    return rows
        .map(
          (r) => ResourceItem.fromJson(
            jsonDecode(r['item_json'].toString()) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  List<String> groups() {
    final rows = _db.handle.select(
      'SELECT DISTINCT group_name FROM favorites ORDER BY group_name',
    );
    return rows.map((r) => r['group_name'].toString()).toList();
  }

  List<ResourceItem> search(String q) {
    final term = q.trim();
    if (term.isEmpty) return list();
    final likeArg = '%${HubDatabase.escapeLike(term)}%';

    final useFts = _db.fts5TrigramAvailable && term.length >= 3;
    final sql = useFts
        ? "SELECT f.item_json FROM favorites f "
              "JOIN favorites_fts t ON t.rowid = f.rowid "
              "WHERE t.favorites_fts MATCH ? ESCAPE '\\' "
              "UNION "
              "SELECT item_json FROM favorites WHERE title LIKE ? ESCAPE '\\' OR clean_title LIKE ? ESCAPE '\\' "
              "ORDER BY updated_at DESC LIMIT 500"
        : "SELECT item_json FROM favorites "
              "WHERE title LIKE ? ESCAPE '\\' OR clean_title LIKE ? ESCAPE '\\' "
              "ORDER BY updated_at DESC LIMIT 500";

    final args = useFts
        ? <Object?>[term, likeArg, likeArg]
        : <Object?>[likeArg, likeArg];
    final rows = _db.handle.select(sql, args);
    return rows
        .map(
          (r) => ResourceItem.fromJson(
            jsonDecode(r['item_json'].toString()) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  /// 收藏：以 favoriteKey 为 PK，UPSERT **不覆盖** note / group
  void add(ResourceItem item) {
    if (_db.readOnly) {
      throw const HubDbException(HubDbError.writeDisabled, 'readOnly');
    }
    final id = item.favoriteKey;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.handle.execute(
      'INSERT INTO favorites(id,title,clean_title,item_json,note,group_name,created_at,updated_at) '
      'VALUES(?,?,?,?,?,?,?,?) '
      'ON CONFLICT(id) DO UPDATE SET '
      '  item_json=excluded.item_json, title=excluded.title, '
      '  clean_title=excluded.clean_title, updated_at=excluded.updated_at',
      <Object?>[
        id,
        item.title,
        item.cleanTitle,
        jsonEncode(item.toJson()),
        '',
        '默认分组',
        now,
        now,
      ],
    );
    // 关键写操作留痕（只记 key 与标题，绝不落链接/凭证）
    HubLogger.i(
      'favorite upsert key=$id title=${item.title.length > 24 ? '${item.title.substring(0, 24)}…' : item.title}',
    );
  }

  void updateMeta(String id, {String? note, String? groupName}) {
    if (_db.readOnly) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.handle.execute(
      'UPDATE favorites SET note=COALESCE(?,note), group_name=COALESCE(?,group_name), '
      'updated_at=? WHERE id=?',
      <Object?>[note, groupName, now, id],
    );
  }

  void delete(String id) {
    if (_db.readOnly) return;
    final n = _db.handle.select(
      'SELECT COUNT(*) AS c FROM favorites WHERE id=?',
      <Object?>[id],
    );
    final before = (n.first['c'] as num?)?.round() ?? 0;
    _db.handle.execute('DELETE FROM favorites WHERE id=?', <Object?>[id]);
    HubLogger.i('favorite delete key=$id existed=$before');
  }

  int count() {
    final r = _db.handle.select('SELECT COUNT(*) AS c FROM favorites');
    return (r.first['c'] as num?)?.round() ?? 0;
  }
}

/// 搜索历史：同词去重置顶，保留 100 条
class HistoryRepo {
  HistoryRepo(this._db);
  final HubDatabase _db;

  void add(String query) {
    if (query.trim().isEmpty || _db.readOnly) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.handle.execute('DELETE FROM history WHERE query=?', <Object?>[query]);
    _db.handle.execute(
      'INSERT INTO history(query, created_at) VALUES(?,?)',
      <Object?>[query, now],
    );
    _db.handle.execute(
      'DELETE FROM history WHERE id NOT IN '
      '(SELECT id FROM history ORDER BY created_at DESC LIMIT 100)',
    );
  }

  List<String> list({int limit = 12}) {
    final rows = _db.handle.select(
      'SELECT query FROM history ORDER BY created_at DESC LIMIT ?',
      <Object?>[limit],
    );
    return rows.map((r) => r['query'].toString()).toList();
  }

  /// 删除单条历史（W2：搜索页历史区支持逐条移除）
  void remove(String query) {
    if (_db.readOnly || query.trim().isEmpty) return;
    _db.handle.execute('DELETE FROM history WHERE query=?', <Object?>[query]);
    HubLogger.i('history remove');
  }

  int count() {
    final r = _db.handle.select('SELECT COUNT(*) AS c FROM history');
    return (r.first['c'] as num?)?.round() ?? 0;
  }

  void clear() {
    if (_db.readOnly) return;
    _db.handle.execute('DELETE FROM history');
    HubLogger.i('history cleared');
  }
}

/// 导入任务仓库
class ImportRepo {
  ImportRepo(this._db);
  final HubDatabase _db;

  static const int maxAttempts = 3;

  int enqueue({
    required String kind,
    required String target,
    required String title,
    String backend = '115',
  }) {
    if (_db.readOnly) {
      throw const HubDbException(HubDbError.writeDisabled, 'readOnly');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.handle.execute(
      'INSERT INTO import_task(kind,target,status,created_at,updated_at,backend,title) '
      'VALUES(?,?,?,?,?,?,?)',
      <Object?>[kind, target, 'pending', now, now, backend, title],
    );
    final res = _db.handle.select('SELECT last_insert_rowid() AS id');
    return (res.first['id'] as num).round();
  }

  void updateStatus(int id, String status, {String? message, int? progress}) {
    if (_db.readOnly) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.handle.execute(
      'UPDATE import_task SET status=?, message=COALESCE(?,message), '
      'progress=COALESCE(?,progress), attempts=attempts+1, updated_at=?, '
      'done_at=? WHERE id=?',
      <Object?>[
        status,
        message,
        progress,
        now,
        (status == 'success' || status == 'failed') ? now : null,
        id,
      ],
    );
  }

  /// 投递成功后的落地：任务进入「云下载中」。
  ///
  /// 【语义修正】V1.x 在这里直接置 `success` 并把进度写死 100 —— 但 115 只是
  /// **接受**了离线任务，云端还在 BT 下载，进度是假的。现在只置 running，
  /// 真实进度交给 `syncCloud()` 从 115 任务列表回填。
  void markSubmitted(int id, {String remoteId = '', String message = ''}) {
    if (_db.readOnly) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.handle.execute(
      'UPDATE import_task SET status=?, message=?, progress=0, '
      "remote_id=COALESCE(NULLIF(?,''), remote_id), updated_at=?, "
      'attempts=attempts+1, done_at=NULL WHERE id=?',
      <Object?>[
        'running',
        message.isEmpty ? '已提交 115 离线任务，等待云端下载' : message,
        remoteId,
        now,
        id,
      ],
    );
  }

  List<Map<String, Object?>> list() =>
      _db.handle.select('SELECT * FROM import_task ORDER BY id DESC LIMIT 200');

  /// 正在排队/进行中的任务（用于决定是否需要轮询云端进度）
  List<Map<String, Object?>> active() => _db.handle.select(
    "SELECT * FROM import_task WHERE status IN ('pending','running') "
    'ORDER BY id DESC LIMIT 200',
  );

  /// 用 115 云端任务列表回填本地任务的**真实进度**（W3）
  ///
  /// 只更新 progress / status / message / remote_id / done_at，**不动 attempts**
  /// —— 同步不是一次投递尝试，累加 attempts 会把重试预算吃光。
  /// 返回本次被回填的任务条数。
  int syncCloud(List<Pan115CloudTask> tasks) {
    if (_db.readOnly || tasks.isEmpty) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    var updated = 0;
    for (final r in list()) {
      final status = r['status']?.toString() ?? '';
      if (status != 'pending' && status != 'running' && status != 'success') {
        continue;
      }
      final hit = matchCloudTask(
        tasks,
        remoteId: (r['remote_id'] ?? '').toString(),
        target: r['target']?.toString() ?? '',
        title: r['title']?.toString() ?? '',
      );
      if (hit == null) continue;
      final id = (r['id'] as num).round();
      final next = hit.finished ? 'success' : 'running';
      final msg =
          '云端 ${hit.statusLabel} · ${hit.percent.toStringAsFixed(1)}%'
          '${hit.name.isEmpty ? '' : ' · ${hit.name}'}';
      _db.handle.execute(
        'UPDATE import_task SET status=?, progress=?, message=?, '
        "remote_id=COALESCE(NULLIF(remote_id,''), ?), updated_at=?, "
        "done_at=CASE WHEN ? IN ('success','failed') THEN ? ELSE done_at END "
        'WHERE id=?',
        <Object?>[
          next,
          hit.percent.round(),
          msg,
          hit.infoHash.isEmpty ? null : hit.infoHash,
          now,
          next,
          now,
          id,
        ],
      );
      updated++;
    }
    if (updated > 0) HubLogger.i('115 云端进度同步：回填 $updated 条');
    return updated;
  }

  /// 清空**全部**本地导入记录（含 pending / running）
  ///
  /// 语义边界：只删本机 `import_task` 表，**不动 115 云端已创建的离线任务**。
  /// 走一条简单 DELETE，不做「全表读 + 应用层过滤」。
  /// 返回实际清理条数（UI 如实回显）；只读库抛 [HubDbException]。
  int clearAll() {
    if (_db.readOnly) {
      throw const HubDbException(HubDbError.writeDisabled, 'readOnly');
    }
    final before = count();
    _db.handle.execute('DELETE FROM import_task');
    HubLogger.i('import cleared count=$before');
    return before;
  }

  /// 本地导入记录总数（清空前的「会删掉多少条」提示用）
  int count() {
    final r = _db.handle.select('SELECT COUNT(*) AS c FROM import_task');
    return (r.first['c'] as num?)?.round() ?? 0;
  }

  void clearFinished() {
    if (_db.readOnly) return;
    _db.handle.execute(
      "DELETE FROM import_task WHERE status IN ('success','failed')",
    );
  }

  Map<String, int> stats() {
    final rows = _db.handle.select(
      'SELECT status, COUNT(*) AS c FROM import_task GROUP BY status',
    );
    final m = <String, int>{
      'pending': 0,
      'running': 0,
      'success': 0,
      'failed': 0,
    };
    for (final r in rows) {
      m[r['status'].toString()] = (r['c'] as num?)?.round() ?? 0;
    }
    return m;
  }
}

/// 推荐快照仓库（hot_snapshot + hot_board_meta）
/// 秒开：UI 直接读快照；失败刷新只写 meta，保留上次成功条目（板块级降级）
class SnapshotRepo {
  SnapshotRepo(this._db);
  final HubDatabase _db;

  void replaceItems(String board, List<ResourceItem> items) {
    if (_db.readOnly) return;
    _db.handle.execute('DELETE FROM hot_snapshot WHERE board=?', <Object?>[
      board,
    ]);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < items.length; i++) {
      _db.handle.execute(
        'INSERT INTO hot_snapshot(board,category,rank,item_json,snapshot_at) '
        "VALUES(?,'video',?,?,?)",
        <Object?>[board, i + 1, jsonEncode(items[i].toJson()), now],
      );
    }
  }

  void writeMeta(
    String board, {
    required String state,
    String message = '',
    int itemCount = 0,
  }) {
    if (_db.readOnly) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.handle.execute(
      'INSERT INTO hot_board_meta(board,category,state,message,item_count,keywords,outcomes,refreshed_at) '
      "VALUES(?,'video',?,?,?,'[]','[]',?) "
      'ON CONFLICT(board) DO UPDATE SET state=excluded.state, message=excluded.message, '
      'item_count=excluded.item_count, refreshed_at=excluded.refreshed_at',
      <Object?>[board, state, message, itemCount, now],
    );
  }

  List<ResourceItem> loadBoard(String board) {
    final rows = _db.handle.select(
      'SELECT item_json FROM hot_snapshot WHERE board=? ORDER BY rank ASC',
      <Object?>[board],
    );
    return rows
        .map(
          (r) => ResourceItem.fromJson(
            jsonDecode(r['item_json'].toString()) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  Map<String, bool> hasCache(List<String> boards) {
    final out = <String, bool>{};
    for (final b in boards) {
      final r = _db.handle.select(
        'SELECT COUNT(*) AS c FROM hot_snapshot WHERE board=?',
        <Object?>[b],
      );
      out[b] = ((r.first['c'] as num?)?.round() ?? 0) > 0;
    }
    return out;
  }
}
