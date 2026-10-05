import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'raw_item.dart';

/// 磁力资源站的常见协议。
///
/// 起因（2026-09-17）：设置页新增自定义源时，无论用户填什么站点，
/// 都被一股脑当成 apibay 协议去请求 `{base}/q.php?q=...`，
/// 于是任何非 apibay 站点必然 404（用户的 m.diao.im / welwel.dpdns.org 即如此）。
///
/// 现在改为：**先按协议探测，命中哪个用哪个**，结果写回源配置，后续直接复用。
enum SourceProtocol {
  apibay,
  bitmagnetRest,
  bitmagnetGraphql,
  torznab,
  genericHtml;

  String get id => name;

  String get label => switch (this) {
    SourceProtocol.apibay => 'apibay JSON',
    SourceProtocol.bitmagnetRest => 'Bitmagnet REST',
    SourceProtocol.bitmagnetGraphql => 'Bitmagnet GraphQL',
    SourceProtocol.torznab => 'Torznab（Jackett / Prowlarr）',
    SourceProtocol.genericHtml => '通用网页抓取',
  };

  static SourceProtocol? tryParse(String? v) {
    if (v == null || v.isEmpty) return null;
    for (final p in values) {
      if (p.name == v) return p;
    }
    return null;
  }
}

/// 探测结果：命中的协议 + 实际可用的 API 基址 + 样例条数
class ProbeResult {
  const ProbeResult({
    required this.protocol,
    required this.apiBase,
    required this.sampleCount,
  });

  final SourceProtocol protocol;
  final String apiBase;
  final int sampleCount;

  /// 协议中文名（UI 展示用）
  String get label => protocol.label;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'protocol': protocol.id,
    'apiBase': apiBase,
    'sampleCount': sampleCount,
  };
}

// ─────────────────────────────────────────────── 基础工具

String _magnet(String hash, String name) =>
    'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeComponent(name)}';

/// magnet 链接正则（覆盖 40 位 hex 与 32 位 base32 infohash）
final RegExp kMagnetRe = RegExp("magnet:\\?[^\\s\"'<>]+", caseSensitive: false);

/// 从 magnet 里取 infohash
String? infoHashFromMagnet(String magnet) {
  final m = RegExp(r'[?&]xt=urn:btih:([A-Za-z0-9]{32,40})').firstMatch(magnet);
  return m?.group(1)?.toLowerCase();
}

String decodeEntities(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ');

int? _asInt(Object? v) {
  if (v is num) return v.round();
  if (v is String) {
    // 容忍 "1.2 GB" 之外的纯数字字符串
    return int.tryParse(v.replaceAll(RegExp(r'[^0-9-]'), ''));
  }
  return null;
}

/// 时间戳归一化为毫秒。容忍秒级 unix、毫秒级、ISO8601。
int? _asMillis(Object? v) {
  if (v == null) return null;
  if (v is num) {
    final n = v.round();
    if (n <= 0) return null;
    // 秒级 unix（10 位）→ 毫秒
    return n < 100000000000 ? n * 1000 : n;
  }
  final s = v.toString();
  if (s.isEmpty) return null;
  final dt = DateTime.tryParse(s);
  if (dt != null) return dt.millisecondsSinceEpoch;
  return null;
}

Map<String, dynamic> _asMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

List<dynamic> _asList(Object? v) => v is List ? v : const <dynamic>[];

// ─────────────────────────────────────────────── 协议解析（纯函数，可脱敏单测）

/// Bitmagnet REST：`GET {base}/api/search?keyword=<kw>`
/// 响应 `{data:{torrents:[{hash,name,size,magnet_uri,files_count,created_at}]}}`
List<RawItem> parseBitmagnetRest(Map<String, dynamic> json) {
  final data = _asMap(json['data']);
  final hasTorrents = data.containsKey('torrents');
  if (!hasTorrents) return const <RawItem>[];
  return _asList(data['torrents'])
      .whereType<Map>()
      .map((raw) {
        final e = raw.cast<String, dynamic>();
        final hash = (e['hash']?.toString() ?? '').toLowerCase();
        final name = (e['name']?.toString() ?? '').trim();
        final magnet = e['magnet_uri']?.toString();
        final size = _asInt(e['size']);
        return RawItem(
          title: name,
          magnet: (magnet != null && magnet.startsWith('magnet:'))
              ? magnet
              : (hash.isNotEmpty ? _magnet(hash, name) : null),
          sizeBytes: size != null && size > 0 ? size : null,
          fileCount: _asInt(e['files_count']),
          publishAt: _asMillis(e['created_at']),
          detailUrl: hash.isNotEmpty ? null : null,
        );
      })
      .where((r) => r.title.isNotEmpty)
      .toList();
}

/// Bitmagnet GraphQL：`{torrentContent{search(items:{infoHash,title,...,torrent{...}})}}`
List<RawItem> parseBitmagnetGraphql(Map<String, dynamic> json) {
  final data = _asMap(json['data']);
  final tc = _asMap(data['torrentContent']);
  final search = tc.containsKey('search') ? _asMap(tc['search']) : data;
  final items = search.containsKey('items')
      ? _asList(search['items'])
      : (search.containsKey('torrents')
            ? _asList(search['torrents'])
            : const []);
  return items
      .whereType<Map>()
      .map((raw) {
        final e = raw.cast<String, dynamic>();
        final t = _asMap(e['torrent']);
        final hash =
            (e['infoHash'] ?? e['hash'])?.toString().toLowerCase() ?? '';
        final title = (e['title'] ?? t['name'] ?? '').toString().trim();
        final magnet = t['magnetUri']?.toString();
        final size = _asInt(t['size']);
        final seeders = _asInt(e['seeders']);
        return RawItem(
          title: title,
          magnet: (magnet != null && magnet.startsWith('magnet:'))
              ? magnet
              : (hash.isNotEmpty ? _magnet(hash, title) : null),
          sizeBytes: size != null && size > 0 ? size : null,
          fileCount: _asInt(t['filesCount']),
          publishAt: _asMillis(e['publishedAt']),
          hotness: seeders?.toDouble() ?? 0,
        );
      })
      .where((r) => r.title.isNotEmpty)
      .toList();
}

/// apibay：`GET {base}/q.php?q=<kw>` → `[{info_hash,name,size,num_files,added,seeders,id}]`
List<RawItem> parseApibay(dynamic decoded, String base) {
  final list = decoded is List ? decoded : const <dynamic>[];
  return list
      .whereType<Map>()
      .map((raw) {
        final e = raw.cast<String, dynamic>();
        final hash = (e['info_hash']?.toString() ?? '').toLowerCase();
        final name = decodeEntities(e['name']?.toString() ?? '').trim();
        final size = _asInt(e['size']);
        final id = e['id']?.toString();
        final seeders = _asInt(e['seeders']);
        return RawItem(
          title: name,
          magnet: hash.isNotEmpty ? _magnet(hash, name) : null,
          sizeBytes: size != null && size > 0 ? size : null,
          fileCount: _asInt(e['num_files']),
          publishAt: _asMillis(e['added']),
          hotness: seeders?.toDouble() ?? 0,
          detailUrl: id != null ? '$base/t.php?id=$id' : null,
        );
      })
      .where((r) => r.title.isNotEmpty)
      .toList();
}

/// Torznab XML → RawItem 列表
List<RawItem> parseTorznabXml(String xml) {
  final out = <RawItem>[];
  final channel = RegExp(
    r'<item>([\s\S]*?)</item>',
    caseSensitive: false,
  ).allMatches(xml);
  for (final m in channel) {
    final block = m.group(1) ?? '';
    String pick(String tag) {
      final mm = RegExp(
        '<$tag>([\\s\\S]*?)</$tag>',
        caseSensitive: false,
      ).firstMatch(block);
      final raw = mm?.group(1) ?? '';
      return decodeEntities(raw.replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), ''))
          .trim();
    }

    final title = pick('title');
    if (title.isEmpty) continue;
    final size = _asInt(pick('size'));
    final enclosure = RegExp(
      r'<enclosure[^>]*url="([^"]+)"',
      caseSensitive: false,
    ).firstMatch(block)?.group(1);
    final magnetRaw = enclosure ?? '';
    final magnetUri = magnetRaw.startsWith('magnet:') ? magnetRaw : null;
    final link = RegExp(
      r'<link>([\s\S]*?)</link>',
      caseSensitive: false,
    ).firstMatch(block)?.group(1);
    var seeders = _asInt(pick('seeders'));
    if (seeders == null) {
      final sAttr = RegExp(
        r'name="seeders"[^>]*value="(\d+)"',
        caseSensitive: false,
      ).firstMatch(block)?.group(1);
      seeders = _asInt(sAttr);
    }
    out.add(
      RawItem(
        title: title,
        magnet: magnetUri,
        sizeBytes: size != null && size > 0 ? size : null,
        publishAt: _asMillis(pick('pubDate')),
        hotness: seeders?.toDouble() ?? 0,
        detailUrl: link?.trim().isEmpty == true
            ? null
            : decodeEntities((link ?? '').trim()),
      ),
    );
  }
  return out;
}

/// 通用网页：从任意 HTML 里抽出所有 magnet 链接及其标题。
///
/// 标题取值优先级：`<a>` 的 title 属性 → `<a>` 文本 → 上一行文本。
List<RawItem> parseGenericHtml(String html, {int max = 60}) {
  final out = <RawItem>[];
  final seen = <String>{};
  // 逐个锚点，取其 href 为 magnet 的链接
  final anchors = RegExp(
    r'<a\b[^>]*href="(magnet:\?[^"]+)"[^>]*>([\s\S]{0,400}?)</a>',
    caseSensitive: false,
  ).allMatches(html);
  for (final a in anchors) {
    final magnet = a.group(1) ?? '';
    final hash = infoHashFromMagnet(magnet);
    if (hash == null) continue;
    if (!seen.add(hash)) continue;
    final inner = a.group(2) ?? '';
    var title = RegExp(r'title="([^"]*)"').firstMatch(inner)?.group(1) ?? '';
    if (title.trim().isEmpty) {
      title = inner.replaceAll(RegExp(r'<[^>]+>'), ' ');
    }
    title = decodeEntities(title).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.isEmpty) continue;
    out.add(
      RawItem(
        title: title,
        magnet: magnet,
        publishAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (out.length >= max) break;
  }
  if (out.isNotEmpty) return out;

  // 锚点没抓到（很多站点把 magnet 放在 JS / data 属性里）→ 直接扫全文
  for (final m in kMagnetRe.allMatches(html)) {
    final magnet = m.group(0) ?? '';
    final hash = infoHashFromMagnet(magnet);
    if (hash == null || !seen.add(hash)) continue;
    out.add(
      RawItem(
        title: '资源 ${hash.substring(0, 12)}…',
        magnet: magnet,
        publishAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (out.length >= max) break;
  }
  return out;
}

/// 从首页 HTML 推断搜索端点（纯函数，便于单测）。
///
/// 思路：取 `<form>` 的 action，配上 form 里第一个 text/search 型 input 的 name。
/// 返回值已把 `{keyword}` 占位符替换为用户关键词。
String? detectSearchUrlFromHtml(String html, String pageUrl) {
  final Uri base;
  try {
    base = Uri.parse(pageUrl);
  } catch (_) {
    return null;
  }
  for (final fm in RegExp(
    r'<form\b([^>]*)>([\s\S]{0,2000}?)</form>',
    caseSensitive: false,
  ).allMatches(html)) {
    final attrs = fm.group(1) ?? '';
    final inner = fm.group(2) ?? '';
    final method =
        RegExp(
          r'method="([^"]*)"',
          caseSensitive: false,
        ).firstMatch(attrs)?.group(1)?.toLowerCase() ??
        'get';
    if (method != 'get') continue; // POST 表单交由策略层跳过，避免误伤
    final action =
        RegExp(
          r'action="([^"]*)"',
          caseSensitive: false,
        ).firstMatch(attrs)?.group(1) ??
        '';
    // form 内的文本输入框 name
    String? param;
    for (final inp in RegExp(
      r'<input\b([^>]*)>',
      caseSensitive: false,
    ).allMatches(inner)) {
      final ia = inp.group(1) ?? '';
      final type =
          RegExp(
            r'type="([^"]*)"',
            caseSensitive: false,
          ).firstMatch(ia)?.group(1)?.toLowerCase() ??
          'text';
      if (type != 'text' && type != 'search') continue;
      final name = RegExp(r'name="([^"]+)"').firstMatch(ia)?.group(1);
      if (name == null || name.isEmpty) continue;
      if (RegExp(r'^(.Button|submit)$', caseSensitive: false).hasMatch(name)) {
        continue;
      }
      param = name;
      break;
    }
    param ??= 'q';
    final Uri target;
    if (action.isEmpty) {
      target = base;
    } else if (action.startsWith('http')) {
      target = Uri.parse(action);
    } else {
      target = base.resolve(action);
    }
    final merged = <String, String>{
      ...target.queryParameters,
      param: kKeywordPlaceholder,
    };
    // 必须手工拼 query：`Uri.queryParameters` 会把 `{keyword}` 编码成
    // `%7Bkeyword%7D`，后续 replaceAll 就再也匹配不上，整条策略会静默失效。
    final qs = merged.entries
        .map((e) {
          final v = e.value == kKeywordPlaceholder
              ? e.value
              : Uri.encodeQueryComponent(e.value);
          return '${Uri.encodeQueryComponent(e.key)}=$v';
        })
        .join('&');
    final scheme = target.scheme.isEmpty ? base.scheme : target.scheme;
    final host = target.host.isEmpty ? base.host : target.host;
    final port = target.hasPort
        ? ':${target.port}'
        : (target.host.isEmpty && base.hasPort ? ':${base.port}' : '');
    final path = target.path.isEmpty ? '/' : target.path;
    return '$scheme://$host$port$path?$qs';
  }
  return null;
}

/// 搜索 URL 模板里的关键词占位符
const String kKeywordPlaceholder = '{keyword}';

// ─────────────────────────────────────────────── HTTP

/// 轻量 HTTP 出口：只服务于源适配器（代理 / UA / 超时）
Future<Response<String>> httpGet(
  String url, {
  String proxy = '',
  int timeoutMs = 8000,
  Map<String, String>? headers,
  bool throwOnStatus = true,
}) async {
  final dio = Dio(
    BaseOptions(
      connectTimeout: Duration(milliseconds: timeoutMs),
      receiveTimeout: Duration(milliseconds: timeoutMs),
      responseType: ResponseType.plain,
      validateStatus: (s) =>
          throwOnStatus ? (s != null && s < 400) : (s != null && s < 500),
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
  return dio.get<String>(
    url,
    options: Options(
      headers: <String, dynamic>{
        'user-agent': kBrowserUa,
        'accept': 'application/json, text/html, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9',
        ...?headers,
      },
    ),
  );
}

Future<Response<String>> httpPostJson(
  String url,
  Object body, {
  String proxy = '',
  int timeoutMs = 8000,
}) async {
  final dio = Dio(
    BaseOptions(
      connectTimeout: Duration(milliseconds: timeoutMs),
      receiveTimeout: Duration(milliseconds: timeoutMs),
      responseType: ResponseType.plain,
      validateStatus: (s) => s != null && s < 500,
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
  return dio.post<String>(
    url,
    data: body,
    options: Options(
      headers: <String, dynamic>{
        'user-agent': kBrowserUa,
        'content-type': 'application/json',
        'accept': 'application/json, text/plain, */*',
      },
    ),
  );
}

const String kBrowserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 归一化用户输入的站点地址为 https(s)://host 形式（去尾斜杠、去路径）
String normalizeSiteBase(String input) {
  var s = input.trim();
  if (s.isEmpty) return s;
  if (!s.contains('://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null) return s;
  final scheme = u.scheme.isEmpty ? 'https' : u.scheme;
  final host = u.host;
  if (host.isEmpty) return s;
  final port = u.hasPort && u.port != 443 && u.port != 80 ? ':${u.port}' : '';
  return '$scheme://$host$port';
}

/// 候选 API 基址：用户填的可能只是站点首页，后端常在 `api.` 子域
/// （实测：八神磁力前端 welwel.dpdns.org → 后端 api.welwel.dpdns.org）
List<String> candidateApiBases(String input) {
  final base = normalizeSiteBase(input);
  final out = <String>[base];
  final u = Uri.tryParse(base);
  if (u == null) return out;
  final host = u.host;
  // 已经是 api.* 就不再加前缀
  if (!host.startsWith('api.') && host.split('.').length >= 2) {
    out.add('${u.scheme}://api.$host');
  }
  return out;
}
