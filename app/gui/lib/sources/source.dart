import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/db/hub_database.dart';
import '../core/util/logger.dart';
import 'raw_item.dart';

export 'raw_item.dart';

/// 资源类型
enum ResourceKind { magnet, pan115 }

/// 归一化后的资源条目（UI 消费的最终形态）
class ResourceItem {
  const ResourceItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.cleanTitle,
    required this.dedupeKey,
    required this.sourceId,
    this.magnetUri,
    this.infohash,
    this.sha1,
    this.secLink,
    this.shareCode,
    this.receiveCode,
    this.sizeBytes,
    this.fileCount,
    this.publishAt,
    this.hotness = 0,
    this.detailUrl,
    this.resolution,
    this.codec,
    this.season,
    this.episode,
    this.note = '',
    this.groupName = '默认分组',
  });

  final String id;
  final ResourceKind kind;
  final String title;
  final String cleanTitle;
  final String dedupeKey;
  final String sourceId;

  final String? magnetUri;
  final String? infohash;
  final String? sha1;
  final String? secLink;
  final String? shareCode;
  final String? receiveCode;

  final int? sizeBytes;
  final int? fileCount;
  final int? publishAt;
  final double hotness;
  final String? detailUrl;

  final String? resolution;
  final String? codec;
  final int? season;
  final int? episode;

  final String note;
  final String groupName;

  /// 收藏去重主键（严格对齐 Electron 版 shared/types.ts favoriteKey）
  String get favoriteKey {
    final ih = infohash?.toLowerCase();
    if (ih != null && ih.isNotEmpty) return 'magnet:$ih';
    final s = sha1?.toLowerCase();
    if (s != null && s.isNotEmpty) return 'pan115:$s';
    final sc = shareCode?.trim();
    if (sc != null && sc.isNotEmpty) return 'share:$sc';
    return 'raw:$id';
  }

  /// 复制用纯文本：优先秒传链接，其次 magnet，最后详情链接
  String get copyTarget =>
      secLink ?? magnetUri ?? (shareCode ?? detailUrl ?? title);

  ResourceItem copyWithNote({String? note, String? groupName}) => ResourceItem(
    id: id,
    kind: kind,
    title: title,
    cleanTitle: cleanTitle,
    dedupeKey: dedupeKey,
    sourceId: sourceId,
    magnetUri: magnetUri,
    infohash: infohash,
    sha1: sha1,
    secLink: secLink,
    shareCode: shareCode,
    receiveCode: receiveCode,
    sizeBytes: sizeBytes,
    fileCount: fileCount,
    publishAt: publishAt,
    hotness: hotness,
    detailUrl: detailUrl,
    resolution: resolution,
    codec: codec,
    season: season,
    episode: episode,
    note: note ?? this.note,
    groupName: groupName ?? this.groupName,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind.name,
    'title': title,
    'cleanTitle': cleanTitle,
    'dedupeKey': dedupeKey,
    'sourceId': sourceId,
    if (magnetUri != null) 'magnetUri': magnetUri,
    if (infohash != null) 'infohash': infohash,
    if (sha1 != null) 'sha1': sha1,
    if (secLink != null) 'secLink': secLink,
    if (shareCode != null) 'shareCode': shareCode,
    if (receiveCode != null) 'receiveCode': receiveCode,
    if (sizeBytes != null) 'sizeBytes': sizeBytes,
    if (fileCount != null) 'fileCount': fileCount,
    if (publishAt != null) 'publishAt': publishAt,
    'hotness': hotness,
    if (detailUrl != null) 'detailUrl': detailUrl,
    if (resolution != null) 'resolution': resolution,
    if (codec != null) 'codec': codec,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
    'note': note,
    'groupName': groupName,
  };

  static ResourceItem fromJson(Map<String, dynamic> j) => ResourceItem(
    id: j['id']?.toString() ?? '',
    kind: j['kind'] == 'pan115' ? ResourceKind.pan115 : ResourceKind.magnet,
    title: j['title']?.toString() ?? '',
    cleanTitle: j['cleanTitle']?.toString() ?? '',
    dedupeKey: j['dedupeKey']?.toString() ?? '',
    sourceId: j['sourceId']?.toString() ?? '',
    magnetUri: j['magnetUri']?.toString(),
    infohash: j['infohash']?.toString(),
    sha1: j['sha1']?.toString(),
    secLink: j['secLink']?.toString(),
    shareCode: j['shareCode']?.toString(),
    receiveCode: j['receiveCode']?.toString(),
    sizeBytes: j['sizeBytes'] is num ? (j['sizeBytes'] as num).round() : null,
    fileCount: j['fileCount'] is num ? (j['fileCount'] as num).round() : null,
    publishAt: j['publishAt'] is num ? (j['publishAt'] as num).round() : null,
    hotness: (j['hotness'] is num) ? (j['hotness'] as num).toDouble() : 0,
    detailUrl: j['detailUrl']?.toString(),
    resolution: j['resolution']?.toString(),
    codec: j['codec']?.toString(),
    season: j['season'] is num ? (j['season'] as num).round() : null,
    episode: j['episode'] is num ? (j['episode'] as num).round() : null,
    note: j['note']?.toString() ?? '',
    groupName: j['groupName']?.toString() ?? '默认分组',
  );
}

/// 源配置（来自 source_site 表）
class SourceLite {
  const SourceLite({
    required this.id,
    required this.name,
    required this.kind,
    required this.enabled,
    required this.priority,
    required this.rateLimitRps,
    required this.timeoutMs,
    required this.demo,
    this.config = const <String, dynamic>{},
  });

  final String id;
  final String name;
  final ResourceKind kind;
  final bool enabled;
  final int priority;
  final double rateLimitRps;
  final int timeoutMs;
  final bool demo;
  final Map<String, dynamic> config;
}

/// 每次检索下发给适配器的上下文
class AdapterContext {
  const AdapterContext({required this.source, required this.proxy});

  final SourceLite source;
  final String proxy;

  void log(String level, String m) => HubLogger.d('[${source.id}] $m');
}

/// 健康检查（可选能力）
class Health {
  const Health({required this.ok, this.message = ''});
  final bool ok;
  final String message;
}

/// 源适配器：真源 / 演示源统一契约（对应 Electron 版 SourceAdapter）
abstract class SourceAdapter {
  const SourceAdapter();

  ResourceKind get kind;

  Future<List<RawItem>> search(String keyword, AdapterContext ctx);

  Future<List<RawItem>>? fetchHot(String board, AdapterContext ctx) => null;

  Future<Health>? healthCheck(AdapterContext ctx) => null;
}

/// 源仓库：读写 source_site（含健康度、启停）
class SourceRepo {
  SourceRepo(this._db);
  final HubDatabase _db;

  List<SourceLite> listAll() {
    final rows = _db.handle.select(
      'SELECT * FROM source_site ORDER BY priority ASC',
    );
    return rows.map((r) {
      Map<String, dynamic> cfg = <String, dynamic>{};
      try {
        cfg = jsonDecode(
          r['config_json']?.toString() ?? '{}',
        ) as Map<String, dynamic>;
      } catch (_) {}
      return SourceLite(
        id: r['id']?.toString() ?? '',
        name: r['name']?.toString() ?? '',
        kind: r['kind']?.toString() == 'pan115'
            ? ResourceKind.pan115
            : ResourceKind.magnet,
        enabled: (r['enabled'] is num) && (r['enabled'] as num) != 0,
        priority: (r['priority'] is num) ? (r['priority'] as num).round() : 100,
        rateLimitRps: (r['rate_limit_rps'] is num)
            ? (r['rate_limit_rps'] as num).toDouble()
            : 1,
        timeoutMs: (r['timeout_ms'] is num)
            ? (r['timeout_ms'] as num).round()
            : 8000,
        demo: cfg['demo'] == true,
        config: cfg,
      );
    }).toList();
  }

  void setEnabled(String id, bool enabled) {
    if (_db.readOnly) return;
    _db.handle.execute('UPDATE source_site SET enabled=? WHERE id=?', <Object?>[
      enabled ? 1 : 0,
      id,
    ]);
  }

  void updateHealth(String id, Health h) {
    if (_db.readOnly) return;
    _db.handle.execute('UPDATE source_site SET health=? WHERE id=?', <Object?>[
      jsonEncode(<String, dynamic>{'ok': h.ok, 'message': h.message}),
      id,
    ]);
  }

  /// 删除自定义源（P0-6：UI 不得自己拼 DELETE）
  ///
  /// 只允许删 `custom-` 前缀，内置源（迁移表产物）不受影响。
  void deleteCustom(String id) {
    if (_db.readOnly) return;
    if (!id.startsWith('custom-')) return;
    _db.handle.execute('DELETE FROM source_site WHERE id=?', <Object?>[id]);
  }

  /// 清理演示源，返回被清理条数（P0-6）
  ///
  /// count + delete 收在同一事务内（合掉架构评审登记的 TR5：读-改-写无事务）。
  int purgeDemo() {
    if (_db.readOnly) return 0;
    _db.handle.execute('BEGIN IMMEDIATE');
    try {
      final n = _db.handle.select(
        "SELECT COUNT(*) AS c FROM source_site WHERE config_json LIKE '%\"demo\":true%'",
      );
      final count = (n.first['c'] as num?)?.round() ?? 0;
      if (count > 0) {
        _db.handle.execute(
          "DELETE FROM source_site WHERE config_json LIKE '%\"demo\":true%'",
        );
      }
      _db.handle.execute('COMMIT');
      return count;
    } catch (_) {
      _db.handle.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 新增自定义源，返回生成的 id（P0-6：UI 不得自己拼 INSERT）
  String insertCustom({
    required String name,
    required ResourceKind kind,
    required String addr,
  }) {
    final id = 'custom-${DateTime.now().millisecondsSinceEpoch}';
    final cfg = kind == ResourceKind.magnet
        ? <String, dynamic>{'custom': true, 'baseUrl': addr}
        : <String, dynamic>{'custom': true, 'shareUrl': addr};
    _db.handle.execute(
      'INSERT INTO source_site(id,name,kind,enabled,priority,rate_limit_rps,timeout_ms,health,config_json) '
      'VALUES(?,?,?,?,?,?,?,?,?)',
      <Object?>[
        id,
        name,
        kind.name,
        1,
        50,
        1,
        8000,
        jsonEncode(<String, dynamic>{'ok': true}),
        jsonEncode(cfg),
      ],
    );
    return id;
  }

  /// 写入协议识别结果（P0-6）
  ///
  /// 由仓储层自己读旧 config 再合并写回 —— UI 不再需要先 `listAll()` 拿 config
  /// 再传回来，JSON 编解码的职责回到数据层。
  void setProtocol(String id, {required String protocol, String apiBase = ''}) {
    if (_db.readOnly) return;
    final rows = _db.handle.select(
      'SELECT config_json FROM source_site WHERE id=?',
      <Object?>[id],
    );
    if (rows.isEmpty) return;
    Map<String, dynamic> cfg = <String, dynamic>{};
    try {
      cfg = jsonDecode(
        rows.first['config_json']?.toString() ?? '{}',
      ) as Map<String, dynamic>;
    } catch (_) {}
    cfg['protocol'] = protocol;
    cfg['apiBase'] = apiBase;
    _db.handle.execute(
      'UPDATE source_site SET config_json=? WHERE id=?',
      <Object?>[jsonEncode(cfg), id],
    );
  }
}

/// 稳定哈希（演示源确定性数据用）
String sha1Hex(String input) => sha1.convert(utf8.encode(input)).toString();
