import 'dart:convert';

import 'protocols.dart';
import 'raw_item.dart';

/// 源协议自动识别
///
/// 起因（2026-09-17）：用户新增 m.diao.im / welwel.dpdns.org 后自检必 404，
/// 根因是所有自定义源被硬编码成 apibay 协议。与其为每个站点写死适配器，
/// 不如让程序自己去问服务端「你到底是什么协议」。
///
/// 策略按**成本从低到高**依次尝试，首个能产出结构化结果的胜出：
///   1. Bitmagnet REST      GET  {base}/api/search?keyword=
///   2. Bitmagnet GraphQL   POST {base} 与 {scheme}://api.{host}
///   3. Torznab             GET  {base}/api/v2.0/indexers/all/results/torznab/api
///   4. apibay              GET  {base}/q.php?q=
///   5. 通用网页抓取         首页推断搜索地址 + magnet 正则
///
class SourceProber {
  SourceProber({
    String? proxy,
    this.timeoutMs = 8000,
    this.probeKeyword = 'ubuntu',
  }) : proxy = proxy ?? '';

  final String proxy;
  final int timeoutMs;

  /// 探测关键词。取中性 / 无版权敏感性的常见开源软件名。
  final String probeKeyword;

  /// 逐协议尝试，返回首个成功的探测结果；全部失败返回 null。
  ///
  /// [onTried] 可选回调，用于向 UI 汇报「正在试第几个协议/失败原因」。
  Future<ProbeResult?> probe(
    String siteUrl, {
    String apiKey = '',
    void Function(String step, bool ok, String detail)? onTried,
  }) async {
    final bases = candidateApiBases(siteUrl);
    final site = normalizeSiteBase(siteUrl);

    Future<ProbeResult?> attempt(
      SourceProtocol proto,
      String apiBase,
      Future<List<RawItem>> Function() run,
    ) async {
      try {
        final items = await run();
        if (items.isNotEmpty) {
          onTried?.call(proto.label, true, '${items.length} 条样例');
          return ProbeResult(
            protocol: proto,
            apiBase: apiBase,
            sampleCount: items.length,
          );
        }
        onTried?.call(proto.label, false, '无结构化结果');
        return null;
      } catch (e) {
        onTried?.call(proto.label, false, _shorter(e));
        return null;
      }
    }

    Future<List<RawItem>> rest() async {
      final url =
          '$site/api/search?keyword=${Uri.encodeComponent(probeKeyword)}';
      final res = await httpGet(url, proxy: proxy, timeoutMs: timeoutMs);
      final body = res.data ?? '';
      if (body.isEmpty) return const <RawItem>[];
      final d = jsonDecode(body);
      return d is Map
          ? parseBitmagnetRest(d.cast<String, dynamic>())
          : const <RawItem>[];
    }

    Future<List<RawItem>> gql(String apiBase) async {
      final payload = <String, dynamic>{
        'query': BitmagnetGraphqlSourceProbe.query,
        'variables': <String, dynamic>{
          'input': <String, dynamic>{
            'queryString': probeKeyword,
            'limit': 5,
            'page': 1,
            'totalCount': true,
            'hasNextPage': true,
          },
        },
      };
      final res = await httpPostJson(
        apiBase,
        payload,
        proxy: proxy,
        timeoutMs: timeoutMs,
      );
      final body = res.data ?? '';
      if (body.isEmpty) return const <RawItem>[];
      final d = jsonDecode(body);
      if (d is! Map) return const <RawItem>[];
      final m = d.cast<String, dynamic>();
      // GraphQL 出错时会返回 {errors:[...]}：这本身就是「不是该协议」的证据
      if (m['errors'] != null) {
        throw StateError('GraphQL 拒绝：${(m['errors'] as List).first}');
      }
      return parseBitmagnetGraphql(m);
    }

    Future<List<RawItem>> torznab() async {
      final url =
          '$site/api/v2.0/indexers/all/results/torznab/api'
          '?apikey=${Uri.encodeComponent(apiKey)}'
          '&t=search&q=${Uri.encodeComponent(probeKeyword)}';
      final res = await httpGet(url, proxy: proxy, timeoutMs: timeoutMs);
      return parseTorznabXml(res.data ?? '');
    }

    Future<List<RawItem>> apibay() async {
      final url =
          '$site/q.php?q=${Uri.encodeComponent(probeKeyword)}&cat=0&page=0';
      final res = await httpGet(url, proxy: proxy, timeoutMs: timeoutMs);
      final body = res.data ?? '';
      if (body.isEmpty) return const <RawItem>[];
      try {
        return parseApibay(jsonDecode(body), site);
      } catch (_) {
        return const <RawItem>[];
      }
    }

    Future<List<RawItem>> html() async {
      final home = await httpGet('$site/', proxy: proxy, timeoutMs: timeoutMs);
      final doc = home.data ?? '';
      final tpl = detectSearchUrlFromHtml(doc, '$site/');
      final urls = <String>[
        ?tpl,
        '$site/search?q={keyword}',
        '$site/s?q={keyword}',
        '$site/?s={keyword}',
        '$site/?q={keyword}',
      ];
      for (final c in urls) {
        try {
          final u = c.replaceAll(
            '{keyword}',
            Uri.encodeComponent(probeKeyword),
          );
          final res = await httpGet(u, proxy: proxy, timeoutMs: timeoutMs);
          final items = parseGenericHtml(res.data ?? '');
          if (items.isNotEmpty) return items;
        } catch (_) {
          // 逐个候选继续
        }
      }
      return const <RawItem>[];
    }

    // 1) REST
    final r1 = await attempt(SourceProtocol.bitmagnetRest, site, rest);
    if (r1 != null) return r1;

    // 2) GraphQL（含 api. 子域派生 —— 实测八神磁力前端与后端不同域）
    for (final b in <String>{...bases}) {
      final rg = await attempt(
        SourceProtocol.bitmagnetGraphql,
        b,
        () => gql(b),
      );
      if (rg != null) return rg;
    }

    // 3) Torznab（多数实例需要 apikey，没有就跳过以免误判）
    if (apiKey.isNotEmpty) {
      final rt = await attempt(SourceProtocol.torznab, site, torznab);
      if (rt != null) return rt;
    }

    // 4) apibay（兼容既有 torrent-index 源）
    final ra = await attempt(SourceProtocol.apibay, site, apibay);
    if (ra != null) return ra;

    // 5) 通用网页抓取（兜底，最贵也最不可靠，放最后）
    final rh = await attempt(SourceProtocol.genericHtml, site, html);
    if (rh != null) return rh;

    return null;
  }

  String _shorter(Object e) {
    final s = e.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}

/// GraphQL 探测用的查询串（与适配器保持一致，避免重复常量导致的漂移）
class BitmagnetGraphqlSourceProbe {
  static const String query = r'''
query TorrentContentSearch($input: TorrentContentSearchQueryInput!) {
  torrentContent {
    search(input: $input) {
      totalCount
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
}
