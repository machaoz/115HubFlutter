import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../core/network/hub_http.dart';
import '../core/util/logger.dart';
import 'source.dart';

/// apibay 协议真源（对应 Electron 版 torrent-index.ts）
/// - 检索：GET {base}/q.php?q=<kw>&cat=0&page=0
/// - 热榜：GET {base}/precompiled/data_top100_recent.json
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
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(milliseconds: timeoutMs),
      receiveTimeout: Duration(milliseconds: timeoutMs),
      responseType: ResponseType.plain,
    ));
    if (proxy.isNotEmpty) {
      dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final c = HttpClient();
        c.findProxy = (uri) => 'PROXY $proxy';
        return c;
      });
    }
    return dio.get<T>(url,
        options: Options(headers: <String, dynamic>{
          'user-agent': kUserAgents.first,
          'accept': 'application/json, text/plain, */*',
        }));
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
      final res = await _get<String>(url,
          proxy: ctx.proxy, timeoutMs: ctx.source.timeoutMs);
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
      publishAt:
          addedSec > 1000000000 ? addedSec * 1000 : DateTime.now().millisecondsSinceEpoch,
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

  /// 热榜（apibay 预编译榜单）
  @override
  Future<List<RawItem>>? fetchHot(String board, AdapterContext ctx) async {
    final base = baseUrl(ctx.source);
    try {
      final res = await _get<String>('$base/precompiled/data_top100_recent.json',
          proxy: ctx.proxy, timeoutMs: ctx.source.timeoutMs);
      final List<dynamic> list =
          jsonDecode(res.data ?? '[]') as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .take(12)
          .map((e) => _toRaw(e, base))
          .toList();
    } catch (e) {
      ctx.log('warn', '热榜失败：$e');
      return const <RawItem>[];
    }
  }
}

/// 演示源：确定性数据，用于无网络/离线回归（PoC 与演示后端）
/// 与 Electron 版一致：跨源首条 hash 相同以验证去重；标题故意带水印以验证清洗。
class DemoSource extends SourceAdapter {
  const DemoSource({this.isPan115 = false});

  final bool isPan115;

  @override
  ResourceKind get kind =>
      isPan115 ? ResourceKind.pan115 : ResourceKind.magnet;

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
        items.add(RawItem(
          title: title,
          sha1: sha,
          secLink: '115://${Uri.encodeComponent(keyword)}|${(_gb[i % _gb.length] * 1024 * 1024 * 1024).round()}|$sha|0',
          sizeBytes: (_gb[i % _gb.length] * 1024 * 1024 * 1024).round(),
          publishAt: DateTime.now()
              .subtract(Duration(days: 30 - i * 3))
              .millisecondsSinceEpoch,
          hotness: (900 - i * 60).toDouble(),
        ));
      } else {
        final hash = i == 0 ? sha1Hex('dup:$keyword') : sha1Hex('$keyword:$i');
        items.add(RawItem(
          title: title,
          magnet: 'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeComponent(title)}',
          sizeBytes: (_gb[i % _gb.length] * 1024 * 1024 * 1024).round(),
          publishAt: DateTime.now()
              .subtract(Duration(days: 20 - i * 2))
              .millisecondsSinceEpoch,
          hotness: (870 - i * 55).toDouble(),
        ));
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

/// 适配器注册表：按 id 前缀分派（对应 Electron 版 registry.ts）
SourceAdapter adapterFor(SourceLite s) {
  final base = s.id.replaceAll(RegExp(r'-\d+$'), '');
  const demos = <String>{
    'demo-magnet-a',
    'demo-magnet-b',
    'demo-pan115',
  };
  if (demos.contains(s.id)) {
    return DemoSource(isPan115: s.id == 'demo-pan115');
  }
  if (base == 'torrent-index') return const TorrentIndexSource();
  // 未知源降级到演示源，避免整链路崩（ degrading 而非崩溃）
  HubLogger.w('未知源 ${s.id}，降级为演示源');
  return const DemoSource();
}
