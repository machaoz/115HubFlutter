// 多协议源解析 + 端到端探测验证
//
// 本机 flutter_tester 被安全策略拦住（WebSocketException），
// 因此用 Dart VM 直接跑等价断言。protocols.dart 里的解析器都是纯函数，无需 Flutter。
//
// 运行： cd app/gui && dart run .tools/source_protocol_check.dart
import 'dart:convert';

import 'package:magnetic115hub/sources/protocols.dart';
import 'package:magnetic115hub/sources/raw_item.dart';
import 'package:magnetic115hub/sources/source_probe.dart';

int pass = 0;
int fail = 0;

void ck(bool cond, String label, [String detail = '']) {
  if (cond) {
    pass++;
    print('  [ok]   $label${detail.isEmpty ? '' : ' -> $detail'}');
  } else {
    fail++;
    print('  [FAIL] $label${detail.isEmpty ? '' : ' -> $detail'}');
  }
}

// ── 真实响应样本（2026-09-17 实测抓取，关键词 ubuntu）

const String realRestBody = '''
{"data":{"keywords":["ubuntu"],"total_count":null,"has_more":true,
 "torrents":[
  {"hash":"43519d14444904f6015e1a0d92018068fb0a49fa",
   "name":"ubuntu-24.04.5.1-desktop-amd64.iso","size":6250332160,
   "magnet_uri":"magnet:?xt=urn:btih:43519d14444904f6015e1a0d92018068fb0a49fa&dn=ubuntu-24.04.5.1-desktop-amd64.iso",
   "single_file":true,"files_count":1,"files":[],"created_at":1789549205,"updated_at":1789549205}
 ]},
 "message":"ok","status":200}''';

const String realGqlBody = '''
{"data":{"torrentContent":{"search":{
  "totalCount":12873,"totalCountIsEstimate":false,"hasNextPage":true,
  "items":[
   {"infoHash":"984f497b242d94527a421904b255e13e58a9c21a",
    "title":"ubuntu-26.04-live-server-s390x.iso",
    "publishedAt":"2026-08-11T00:00:00Z","seeders":6,"leechers":1,
    "torrent":{"name":"ubuntu-26.04-live-server-s390x.iso","size":769673216,
               "filesCount":1,
               "magnetUri":"magnet:?xt=urn:btih:984f497b242d94527a421904b255e13e58a9c21a&dn=ubuntu-26.04-live-server-s390x.iso"}}
  ]}}}}''';

const String fakeTorznab = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
<item>
 <title><![CDATA[Ubuntu 24.04 Desktop amd64]]></title>
 <link>https://example.org/details/1</link>
 <pubDate>Mon, 11 Aug 2026 00:00:00 GMT</pubDate>
 <enclosure url="magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&amp;dn=Ubuntu" length="5368709120" type="application/x-bittorrent" />
 <torznab:attr name="seeders" value="42"/>
</item>
</channel></rss>''';

const String fakeHtml = '''
<html><body>
<div class="r"><a href="magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&amp;dn=Demo.Movie.2026" title="Demo Movie 2026 1080p">Demo Movie 2026 1080p</a></div>
</body></html>''';

const String formHtml = '''
<form method="get" action="/search">
  <input type="text" name="keyword" id="q" placeholder="搜索…">
  <input type="submit" value="搜索">
</form>''';

void main() async {
  print('== Bitmagnet REST 解析（m.diao.im 真实样本）==');
  final restItems = parseBitmagnetRest(
    jsonDecode(realRestBody) as Map<String, dynamic>,
  );
  ck(restItems.length == 1, '解析出 1 条', '${restItems.length}');
  if (restItems.isNotEmpty) {
    final it = restItems.first;
    ck(it.title == 'ubuntu-24.04.5.1-desktop-amd64.iso', '标题', it.title);
    ck(
      it.magnet?.startsWith('magnet:?xt=urn:btih:43519d14') == true,
      'magnet 保留服务端原值',
    );
    ck(it.sizeBytes == 6250332160, '大小', '${it.sizeBytes}');
    ck(it.fileCount == 1, '文件数', '${it.fileCount}');
    ck(it.publishAt == 1789549205000, 'created_at 秒→毫秒', '${it.publishAt}');
  }

  print('== Bitmagnet GraphQL 解析（八神磁力真实样本）==');
  final gqlItems = parseBitmagnetGraphql(
    jsonDecode(realGqlBody) as Map<String, dynamic>,
  );
  ck(gqlItems.length == 1, '解析出 1 条', '${gqlItems.length}');
  if (gqlItems.isNotEmpty) {
    final it = gqlItems.first;
    ck(it.title.startsWith('ubuntu-26.04'), '标题', it.title);
    ck(
      it.magnet?.contains('984f497b242d94527a421904b255e13e58a9c21a') == true,
      'magnet 取自 torrent.magnetUri',
    );
    ck(it.sizeBytes == 769673216, '大小', '${it.sizeBytes}');
    ck(it.hotness == 6, '种子数作为热度', '${it.hotness}');
    ck(it.publishAt != null, 'publishedAt 解析', '${it.publishAt}');
  }

  print('== Torznab XML 解析 ==');
  final zn = parseTorznabXml(fakeTorznab);
  ck(zn.length == 1, '解析出 1 条', '${zn.length}');
  if (zn.isNotEmpty) {
    ck(
      zn.first.title == 'Ubuntu 24.04 Desktop amd64',
      '标题（剥离 CDATA）',
      zn.first.title,
    );
    ck(
      zn.first.magnet?.contains('aaaaaaaaaaaa') == true,
      'magnet 来自 enclosure',
    );
    ck(zn.first.hotness == 42, 'torznab:attr seeders', '${zn.first.hotness}');
  }

  print('== 通用网页抓取 ==');
  final htmlItems = parseGenericHtml(fakeHtml);
  ck(htmlItems.length == 1, '解析出 1 条', '${htmlItems.length}');
  if (htmlItems.isNotEmpty) {
    ck(
      htmlItems.first.title == 'Demo Movie 2026 1080p',
      '标题取自 title 属性',
      htmlItems.first.title,
    );
    ck(htmlItems.first.magnet?.contains('bbbbbbbb') == true, 'magnet 抽取');
  }
  ck(parseGenericHtml('<p>什么都没有</p>').isEmpty, '无 magnet 时返回空');

  print('== 表单搜索地址推断 ==');
  final u = detectSearchUrlFromHtml(formHtml, 'https://demo.example.org/');
  ck(
    u == 'https://demo.example.org/search?keyword={keyword}',
    'GET 表单 + text input',
    '$u',
  );
  ck(
    detectSearchUrlFromHtml('<div>no form</div>', 'https://a.b/') == null,
    '无表单返回 null',
  );
  ck(
    detectSearchUrlFromHtml(
          '<form method="post" action="/s"><input type="text" name="k"></form>',
          'https://a.b/',
        ) ==
        null,
    'POST 表单跳过（避免误伤）',
  );

  print('== 地址归一与派生 ==');
  ck(
    normalizeSiteBase('m.diao.im/') == 'https://m.diao.im',
    '裸域名补 https',
    normalizeSiteBase('m.diao.im/'),
  );
  ck(
    candidateApiBases('https://welwel.dpdns.org/')
        .contains('https://api.welwel.dpdns.org'),
    '派生 api. 子域（八神磁力前后端不同域）',
  );
  ck(
    infoHashFromMagnet(
          'magnet:?xt=urn:btih:984F497B242D94527A421904B255E13E58A9C21A&dn=x',
        ) ==
        '984f497b242d94527a421904b255e13e58a9c21a',
    'infohash 提取并转小写',
  );

  print('== 协议枚举 ==');
  ck(
    SourceProtocol.tryParse('bitmagnetRest') == SourceProtocol.bitmagnetRest,
    'tryParse 命中',
  );
  ck(SourceProtocol.tryParse('nope') == null, '未知协议返回 null');
  ck(
    SourceProtocol.values.length == 5,
    '协议总数 5',
    '${SourceProtocol.values.length}',
  );

  // ── 端到端：真实站点自动识别（需要网络，失败不判 fail，仅提示）
  print('== 端到端自动识别（需要网络）==');
  await e2e('https://m.diao.im/', SourceProtocol.bitmagnetRest);
  await e2e('https://welwel.dpdns.org/', SourceProtocol.bitmagnetGraphql);

  print('');
  print('----------------------------------------');
  print('通过 $pass 条，失败 $fail 条');
  if (fail > 0) {
    print('!!! 存在失败断言，不得交付');
    throw StateError('assertion failed');
  }
  print('全部通过 ✅');
}

Future<void> e2e(String site, SourceProtocol expect) async {
  final prober = SourceProber(timeoutMs: 15000);
  try {
    final r = await prober.probe(site);
    if (r == null) {
      print('  [skip] $site -> 未识别（本次无网络或站点不可用）');
      return;
    }
    ck(
      r.protocol == expect,
      '$site 被识别为 ${expect.label}',
      '实际=${r.protocol.label} apiBase=${r.apiBase} 样例=${r.sampleCount}',
    );
  } catch (e) {
    print('  [skip] $site -> 网络异常：$e');
  }
}
