import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../core/network/hub_http.dart';
import '../core/util/logger.dart';
import 'protocols.dart';
import 'source.dart';

/// apibay 协议真源（对应 Electron 版 torrent-index.ts）
/// - 检索：GET `{base}/q.php?q=<kw>&cat=0&page=0`
/// - 热榜：GET `{base}/precompiled/data_top100_recent.json`
class TorrentIndexSource extends SourceAdapter {
  const TorrentIndexSource();

  @override
  ResourceKind get kind => ResourceKind.magnet;

  String baseUrl(SourceLite s) {
    final b = (s.config['baseUrl'] as String?) ?? '';
    return b.isEmpty ? 'https://apibay.org' : b;
  }

  /// 纯华语/日韩词在英文索引里必然 0 结果 —— 诚实返回空，不做无效请求
  bool _isChineseOnly(String kw) =>
      RegExp(r'^[\u4e00-\u9fa5\u3040-\u30ff\uac00-\ud7af]+$').hasMatch(kw);

  Future<Response<T>> _get<T>(
    String url, {
    String proxy = '',
    int timeoutMs = 10000,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: Duration(milliseconds: timeoutMs),
        receiveTimeout: Duration(milliseconds: timeoutMs),
        responseType: ResponseType.plain,
      ),
    );
    if (proxy.isNotEmpty) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.findProxy = (uri) => 'PROXY $proxy';
          return c;
        },
      );
    }
    return dio.get<T>(
      url,
      options: Options(
        headers: <String, dynamic>{
          'user-agent': kUserAgents.first,
          'accept': 'application/json, text/plain, */*',
        },
      ),
    );
  }

  @override
  Future<List<RawItem>> search(String keyword, AdapterContext ctx) async {
    if (_isChineseOnly(keyword)) {
      ctx.log('warn', '纯中文/日韩词索引源无结果：$keyword');
      return const <RawItem>[];
    }
    final base = baseUrl(ctx.source);
    final url = '$base/q.php?q=${Uri.encodeComponent(keyword)}&cat=0&page=0';
    try {
      final res = await _get<String>(
        url,
        proxy: ctx.proxy,
        timeoutMs: ctx.source.timeoutMs,
      );
      final body = res.data ?? '';
      if (body.isEmpty) return const <RawItem>[];
      final List<dynamic> list;
      try {
        list = jsonDecode(body) as List<dynamic>;
      } catch (_) {
        ctx.log('warn', '响应非 JSON');
        return const <RawItem>[];
      }
      return list
          .whereType<Map<String, dynamic>>()
          .take(60)
          .map((e) => _toRaw(e, base))
          .where((r) => r.title.isNotEmpty)
          .toList();
    } catch (e) {
      ctx.log('warn', '检索失败：$e');
      rethrow;
    }
  }

  RawItem _toRaw(Map<String, dynamic> e, String base) {
    final hash = (e['info_hash']?.toString() ?? '').toLowerCase();
    final name = _decodeHtmlEntities(e['name']?.toString() ?? '');
    final size = int.tryParse(e['size']?.toString() ?? '') ?? 0;
    final files = int.tryParse(e['num_files']?.toString() ?? '');
    final addedSec = int.tryParse(e['added']?.toString() ?? '') ?? 0;
    final seeders = int.tryParse(e['seeders']?.toString() ?? '') ?? 0;
    final id = e['id']?.toString();
    return RawItem(
      title: name,
      magnet: _magnetUri(hash, name),
      sizeBytes: size > 0 ? size : null,
      fileCount: files,
      publishAt: addedSec > 1000000000
          ? addedSec * 1000
          : DateTime.now().millisecondsSinceEpoch,
      hotness: seeders.toDouble(),
      detailUrl: id != null ? '$base/t.php?id=$id' : null,
    );
  }

  static String _magnetUri(String hash, String name) =>
      'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeComponent(name)}';

  static String _decodeHtmlEntities(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  /// 热榜（apibay 预编译榜单）：全量透出，由 UI 决定展示条数
  @override
  Future<List<RawItem>>? fetchHot(String board, AdapterContext ctx) async {
    final base = baseUrl(ctx.source);
    try {
      final res = await _get<String>(
        '$base/precompiled/data_top100_recent.json',
        proxy: ctx.proxy,
        timeoutMs: ctx.source.timeoutMs,
      );
      final List<dynamic> list = jsonDecode(res.data ?? '[]') as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .take(100)
          .map((e) => _toRaw(e, base))
          .where((r) => r.title.isNotEmpty)
          .toList();
    } catch (e) {
      ctx.log('warn', '热榜失败：$e');
      return const <RawItem>[];
    }
  }
}

/// 未登记源：明确返回空并记录告警，**绝不静默降级到演示数据**。
/// （研发期曾把未知源降级为 DemoSource，导致界面出现虚假条目，已移除。）
class UnsupportedSource extends SourceAdapter {
  const UnsupportedSource();

  @override
  ResourceKind get kind => ResourceKind.magnet;

  @override
  Future<List<RawItem>> search(String keyword, AdapterContext ctx) async {
    HubLogger.w('未登记的数据源 ${ctx.source.id}（${ctx.source.name}），返回空结果');
    return const <RawItem>[];
  }
}

/// 演示源：确定性数据，用于无网络/离线回归（PoC 与演示后端）
/// 与 Electron 版一致：跨源首条 hash 相同以验证去重；标题故意带水印以验证清洗。
class DemoSource extends SourceAdapter {
  const DemoSource({this.isPan115 = false});

  final bool isPan115;

  @override
  ResourceKind get kind => isPan115 ? ResourceKind.pan115 : ResourceKind.magnet;

  static const List<double> _gb = <double>[1.4, 2.1, 4.5, 8.7, 13.6, 23.8];
  static const List<String> _editions = <String>[
    'BluRay REMUX',
    'WEB-DL',
    '1080p x264',
    '2160p HEVC',
    'HDRip',
    'BDRip',
  ];

  @override
  Future<List<RawItem>> search(String keyword, AdapterContext ctx) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final items = <RawItem>[];
    for (var i = 0; i < 6; i++) {
      final title = i == 0
          ? '$keyword ${_editions[i]} ［www.btXXx.com］'
          : '$keyword ${_editions[i]} 演示资源 ${i + 1}';
      if (isPan115) {
        final sha = sha1Hex('115:$keyword:$i');
        items.add(
          RawItem(
            title: title,
            sha1: sha,
            secLink:
                '115://${Uri.encodeComponent(keyword)}|${(_gb[i % _gb.length] * 1024 * 1024 * 1024).round()}|$sha|0',
            sizeBytes: (_gb[i % _gb.length] * 1024 * 1024 * 1024).round(),
            publishAt: DateTime.now()
                .subtract(Duration(days: 30 - i * 3))
                .millisecondsSinceEpoch,
            hotness: (900 - i * 60).toDouble(),
          ),
        );
      } else {
        final hash = i == 0 ? sha1Hex('dup:$keyword') : sha1Hex('$keyword:$i');
        items.add(
          RawItem(
            title: title,
            magnet:
                'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeComponent(title)}',
            sizeBytes: (_gb[i % _gb.length] * 1024 * 1024 * 1024).round(),
            publishAt: DateTime.now()
                .subtract(Duration(days: 20 - i * 2))
                .millisecondsSinceEpoch,
            hotness: (870 - i * 55).toDouble(),
          ),
        );
      }
    }
    return items;
  }

  @override
  Future<List<RawItem>>? fetchHot(String board, AdapterContext ctx) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    const pool = <List<String>>[
      ['肖申克的救赎', '9.7'],
      ['霸王别姬', '9.6'],
      ['这个杀手不太冷', '9.4'],
      ['阿甘正传', '9.5'],
      ['泰坦尼克号', '9.5'],
      ['千与千寻', '9.4'],
      ['美丽人生', '9.5'],
      ['辛德勒的名单', '9.6'],
      ['盗梦空间', '9.4'],
      ['疯狂动物城', '9.2'],
      ['让子弹飞', '9.0'],
      ['活着', '9.3'],
    ];
    return pool.map((e) {
      final title = e[0];
      final rate = e[1];
      if (isPan115) {
        final sha = sha1Hex('115hot:$title');
        return RawItem(
          title: '$title 演示海报 $rate',
          sha1: sha,
          secLink: '115://${Uri.encodeComponent(title)}|2147483648|$sha|0',
          hotness: 940,
        );
      }
      final hash = sha1Hex('hot:$title');
      return RawItem(
        title: '$title 演示海报 $rate',
        magnet: 'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeComponent(title)}',
        hotness: board == 'hot' ? 870 : (board == 'latest' ? 900 : 940),
      );
    }).toList();
  }
}

// ─────────────────────────────────────────────── 多协议源（自动识别后使用）

/// Bitmagnet REST：`GET {base}/api/search?keyword=<kw>`，keyword 至少 2 字符。
/// 实测站点：https://m.diao.im （Bitmagnet Next Web）
class BitmagnetRestSource extends SourceAdapter {
  const BitmagnetRestSource();

  @override
  ResourceKind get kind => ResourceKind.magnet;

  @override
  Future<List<RawItem>> search(String keyword, AdapterContext ctx) async {
    final base =
        (ctx.source.config['apiBase'] as String?) ??
        normalizeSiteBase(ctx.source.config['baseUrl']?.toString() ?? '');
    final url = '$base/api/search?keyword=${Uri.encodeComponent(keyword)}';
    try {
      final res = await httpGet(
        url,
        proxy: ctx.proxy,
        timeoutMs: ctx.source.timeoutMs,
      );
      final body = res.data ?? '';
      if (body.isEmpty) return const <RawItem>[];
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const <RawItem>[];
      return parseBitmagnetRest(decoded.cast<String, dynamic>())
          .take(60)
          .toList();
    } catch (e) {
      ctx.log('warn', '检索失败：$e');
      rethrow;
    }
  }

  @override
  Future<Health>? healthCheck(AdapterContext ctx) async {
    try {
      final items = await search('ubuntu', ctx);
      return Health(ok: items.isNotEmpty, message: '探测到 ${items.length} 条');
    } catch (e) {
      return Health(ok: false, message: 'Bitmagnet REST 不可用：$e');
    }
  }
}

/// Bitmagnet GraphQL：`POST {api}` with `{query, variables}`。
/// 实测站点：https://welwel.dpdns.org（八神磁力，后端在 api. 子域）
class BitmagnetGraphqlSource extends SourceAdapter {
  const BitmagnetGraphqlSource();

  static const String _query = r'''
query TorrentContentSearch($input: TorrentContentSearchQueryInput!) {
  torrentContent {
    search(input: $input) {
      totalCount
      totalCountIsEstimate
      hasNextPage
      items {
        infoHash
        title
        publishedAt
        seeders
        leechers
        torrent { name size filesCount magnetUri }
      }
    }
  }
}''';

  static Map<String, dynamic> _body(String kw, {int limit = 30}) =>
      <String, dynamic>{
        'query': _query,
        'variables': <String, dynamic>{
          'input': <String, dynamic>{
            'queryString': kw,
            'limit': limit,
            'page': 1,
            'totalCount': true,
            'hasNextPage': true,
            'orderBy': <Map<String, dynamic>>[
              <String, dynamic>{'field': 'published_at', 'descending': true},
            ],
          },
        },
      };

  @override
  ResourceKind get kind => ResourceKind.magnet;

  @override
  Future<List<RawItem>> search(String keyword, AdapterContext ctx) async {
    final api =
        (ctx.source.config['apiBase'] as String?) ??
        normalizeSiteBase(ctx.source.config['baseUrl']?.toString() ?? '');
    try {
      final res = await httpPostJson(
        api,
        _body(keyword),
        proxy: ctx.proxy,
        timeoutMs: ctx.source.timeoutMs,
      );
      final body = res.data ?? '';
      if (body.isEmpty) return const <RawItem>[];
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const <RawItem>[];
      final map = decoded.cast<String, dynamic>();
      if (map['errors'] != null) {
        throw StateError('GraphQL 错误：${map['errors']}');
      }
      return parseBitmagnetGraphql(map).take(60).toList();
    } catch (e) {
      ctx.log('warn', '检索失败：$e');
      rethrow;
    }
  }

  @override
  Future<Health>? healthCheck(AdapterContext ctx) async {
    try {
      final items = await search('ubuntu', ctx);
      return Health(ok: items.isNotEmpty, message: '探测到 ${items.length} 条');
    } catch (e) {
      return Health(ok: false, message: 'Bitmagnet GraphQL 不可用：$e');
    }
  }
}

/// Torznab（Jackett / Prowlarr）：XML 结果，通常需要 apikey。
class TorznabSource extends SourceAdapter {
  const TorznabSource();

  @override
  ResourceKind get kind => ResourceKind.magnet;

  String _searchUrl(SourceLite s, String kw) {
    final base =
        (s.config['apiBase'] as String?) ??
        normalizeSiteBase(s.config['baseUrl']?.toString() ?? '');
    final key = (s.config['apiKey'] as String?) ?? '';
    final path =
        (s.config['torznabPath'] as String?) ??
        '/api/v2.0/indexers/all/results/torznab/api';
    return '$base$path?apikey=${Uri.encodeComponent(key)}'
        '&t=search&q=${Uri.encodeComponent(kw)}';
  }

  @override
  Future<List<RawItem>> search(String keyword, AdapterContext ctx) async {
    try {
      final res = await httpGet(
        _searchUrl(ctx.source, keyword),
        proxy: ctx.proxy,
        timeoutMs: ctx.source.timeoutMs,
      );
      final body = res.data ?? '';
      if (body.isEmpty) return const <RawItem>[];
      return parseTorznabXml(body).take(60).toList();
    } catch (e) {
      ctx.log('warn', '检索失败：$e');
      rethrow;
    }
  }
}

/// 通用网页抓取：先从首页推断搜索地址，再从结果页抽取 magnet。
class GenericHtmlSource extends SourceAdapter {
  const GenericHtmlSource();

  @override
  ResourceKind get kind => ResourceKind.magnet;

  /// 由首页推断出的搜索模板（记为 `searchUrl`，含 `{keyword}` 占位符）
  String? _template(SourceLite s) => s.config['searchUrl'] as String?;

  @override
  Future<List<RawItem>> search(String keyword, AdapterContext ctx) async {
    final base =
        (ctx.source.config['apiBase'] as String?) ??
        normalizeSiteBase(ctx.source.config['baseUrl']?.toString() ?? '');
    final tpl = _template(ctx.source);
    final candidates = <String>[
      ?tpl,
      '$base/search?q={keyword}',
      '$base/s?q={keyword}',
      '$base/?s={keyword}',
      '$base/search?keyword={keyword}',
      '$base/?q={keyword}',
    ];
    Object? lastErr;
    for (final c in candidates) {
      final url = c.replaceAll('{keyword}', Uri.encodeComponent(keyword));
      try {
        final res = await httpGet(
          url,
          proxy: ctx.proxy,
          timeoutMs: ctx.source.timeoutMs,
        );
        final items = parseGenericHtml(res.data ?? '').take(60).toList();
        if (items.isNotEmpty) return items;
      } catch (e) {
        lastErr = e;
      }
    }
    if (lastErr != null) {
      ctx.log('warn', '检索失败：$lastErr');
      throw lastErr;
    }
    return const <RawItem>[];
  }
}

/// 适配器注册表：按**协议**分派（对应 Electron 版 registry.ts）
///
/// 旧实现把 `custom-*` 一律当成 apibay，导致任何非 apibay 站点必然 404。
/// 现在读 config.protocol；没有则先由上层跑一次自动探测写回。
SourceAdapter adapterFor(SourceLite s) {
  final base = s.id.replaceAll(RegExp(r'-\d+$'), '');
  const demos = <String>{'demo-magnet-a', 'demo-magnet-b', 'demo-pan115'};
  if (demos.contains(s.id)) {
    return DemoSource(isPan115: s.id == 'demo-pan115');
  }

  final proto = SourceProtocol.tryParse(s.config['protocol'] as String?);
  final adapter = switch (proto) {
    SourceProtocol.apibay => const TorrentIndexSource(),
    SourceProtocol.bitmagnetRest => const BitmagnetRestSource(),
    SourceProtocol.bitmagnetGraphql => const BitmagnetGraphqlSource(),
    SourceProtocol.torznab => const TorznabSource(),
    SourceProtocol.genericHtml => const GenericHtmlSource(),
    null => null,
  };
  if (adapter != null) return adapter;

  // 兼容旧数据：没有 protocol 时按 id 前缀回落到 apibay
  if (base == 'torrent-index' || base == 'custom') {
    return const TorrentIndexSource();
  }
  // 未登记源：明确空结果 + 告警，**不再降级为演示源**（避免虚假数据上屏）
  HubLogger.w('未登记的数据源 ${s.id}（${s.name}），按空结果处理');
  return const UnsupportedSource();
}
