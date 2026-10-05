// 多协议源解析回归护栏
//
// 背景（2026-09-17）：设置页新增自定义源时，无论用户填什么站点都被当成 apibay，
// 导致 m.diao.im / welwel.dpdns.org 这类 Bitmagnet 系站点必然 404。
// 修复后支持 5 种协议自动识别，这里把各协议的解析逻辑固化下来。
//
// 本机 flutter_tester 被安全策略拦截时，可用等价脚本验证：
//   dart run app/gui/.tools/source_protocol_check.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/sources/protocols.dart';
import 'package:magnetic115hub/sources/raw_item.dart';

const String _restSample = '''
{"data":{"keywords":["ubuntu"],"total_count":null,"has_more":true,
 "torrents":[
  {"hash":"43519d14444904f6015e1a0d92018068fb0a49fa",
   "name":"ubuntu-24.04.5.1-desktop-amd64.iso","size":6250332160,
   "magnet_uri":"magnet:?xt=urn:btih:43519d14444904f6015e1a0d92018068fb0a49fa&dn=ubuntu-24.04.5.1-desktop-amd64.iso",
   "single_file":true,"files_count":1,"files":[],"created_at":1789549205,"updated_at":1789549205}
 ]},"message":"ok","status":200}''';

const String _gqlSample = '''
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

const String _torznabSample = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
<item>
 <title><![CDATA[Ubuntu 24.04 Desktop amd64]]></title>
 <link>https://example.org/details/1</link>
 <pubDate>Mon, 11 Aug 2026 00:00:00 GMT</pubDate>
 <enclosure url="magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&amp;dn=Ubuntu" length="5368709120" type="application/x-bittorrent" />
 <torznab:attr name="seeders" value="42"/>
</item>
</channel></rss>''';

const String _htmlSample = '''
<html><body>
<div class="r"><a href="magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&amp;dn=Demo" title="Demo Movie 2026 1080p">Demo Movie 2026 1080p</a></div>
</body></html>''';

void main() {
  group('Bitmagnet REST 解析', () {
    final items = parseBitmagnetRest(
      jsonDecode(_restSample) as Map<String, dynamic>,
    );

    test('解析出条目', () => expect(items.length, 1));
    test(
      '标题',
      () => expect(items.first.title, 'ubuntu-24.04.5.1-desktop-amd64.iso'),
    );
    test(
      '保留服务端 magnet_uri',
      () => expect(
        items.first.magnet,
        startsWith('magnet:?xt=urn:btih:43519d14'),
      ),
    );
    test('大小', () => expect(items.first.sizeBytes, 6250332160));
    test('created_at 秒转毫秒', () => expect(items.first.publishAt, 1789549205000));
    test(
      '空响应不炸',
      () => expect(parseBitmagnetRest(<String, dynamic>{}), isEmpty),
    );
  });

  group('Bitmagnet GraphQL 解析', () {
    final items = parseBitmagnetGraphql(
      jsonDecode(_gqlSample) as Map<String, dynamic>,
    );

    test('解析出条目', () => expect(items.length, 1));
    test('标题', () => expect(items.first.title, startsWith('ubuntu-26.04')));
    test(
      'magnet 取自 torrent.magnetUri',
      () => expect(
        items.first.magnet,
        contains('984f497b242d94527a421904b255e13e58a9c21a'),
      ),
    );
    test('种子数作为热度', () => expect(items.first.hotness, 6));
    test(
      'publishedAt 走 ISO8601',
      () => expect(items.first.publishAt, isNotNull),
    );
  });

  group('Torznab XML 解析', () {
    final items = parseTorznabXml(_torznabSample);
    test('解析出条目', () => expect(items.length, 1));
    test(
      '剥离 CDATA',
      () => expect(items.first.title, 'Ubuntu 24.04 Desktop amd64'),
    );
    test(
      'magnet 来自 enclosure',
      () => expect(items.first.magnet, contains('aaaaaaaaaaaa')),
    );
    test('torznab:attr seeders', () => expect(items.first.hotness, 42));
  });

  group('通用网页抓取', () {
    final items = parseGenericHtml(_htmlSample);
    test('解析出条目', () => expect(items.length, 1));
    test(
      '标题取自 title 属性',
      () => expect(items.first.title, 'Demo Movie 2026 1080p'),
    );
    test(
      '无 magnet 返回空',
      () => expect(parseGenericHtml('<p>什么都没有</p>'), isEmpty),
    );
  });

  group('表单搜索地址推断', () {
    test('GET 表单 + text input', () {
      expect(
        detectSearchUrlFromHtml(
          '<form method="get" action="/search">'
              '<input type="text" name="keyword" id="q">'
              '<input type="submit" value="搜索"></form>',
          'https://demo.example.org/',
        ),
        'https://demo.example.org/search?keyword={keyword}',
      );
    });

    // 占位符若被 URL 编码成 %7Bkeyword%7D，后续替换会全部失效，
    // 这条断言专门守着这个坑。
    test('关键词占位符保持原样，不得被编码', () {
      final u = detectSearchUrlFromHtml(
        '<form method="get"><input type="text" name="q"></form>',
        'https://demo.example.org/',
      );
      expect(u, contains('{keyword}'));
      expect(u, isNot(contains('%7B')));
    });

    test('无表单返回 null', () {
      expect(
        detectSearchUrlFromHtml('<div>no form</div>', 'https://a.b/'),
        isNull,
      );
    });

    test('POST 表单跳过', () {
      expect(
        detectSearchUrlFromHtml(
          '<form method="post" action="/s"><input type="text" name="k"></form>',
          'https://a.b/',
        ),
        isNull,
      );
    });
  });

  group('地址归一与派生', () {
    test(
      '裸域名补 https',
      () => expect(normalizeSiteBase('m.diao.im/'), 'https://m.diao.im'),
    );
    test('派生 api. 子域', () {
      expect(
        candidateApiBases('https://welwel.dpdns.org/'),
        contains('https://api.welwel.dpdns.org'),
      );
    });
    test('infohash 提取转小写', () {
      expect(
        infoHashFromMagnet(
          'magnet:?xt=urn:btih:984F497B242D94527A421904B255E13E58A9C21A&dn=x',
        ),
        '984f497b242d94527a421904b255e13e58a9c21a',
      );
    });
  });

  group('协议枚举', () {
    test('tryParse 命中', () {
      expect(
        SourceProtocol.tryParse('bitmagnetRest'),
        SourceProtocol.bitmagnetRest,
      );
    });
    test('未知返回 null', () => expect(SourceProtocol.tryParse('nope'), isNull));
    test('协议总数', () => expect(SourceProtocol.values.length, 5));
  });

  group('不变量', () {
    // 任何解析器在遇到垃圾输入时都必须返回空列表，不得抛异常——
    // 源站点返回的脏数据不该让整次检索崩掉。
    test('脏输入不抛异常', () {
      expect(
        () => parseBitmagnetRest(<String, dynamic>{'x': 1}),
        returnsNormally,
      );
      expect(() => parseBitmagnetGraphql(<String, dynamic>{}), returnsNormally);
      expect(() => parseTorznabXml(''), returnsNormally);
      expect(() => parseTorznabXml('不是 XML'), returnsNormally);
      expect(() => parseGenericHtml(''), returnsNormally);
    });

    test('解析结果标题均非空', () {
      for (final it in <List<RawItem>>[
        parseBitmagnetRest(jsonDecode(_restSample) as Map<String, dynamic>),
        parseBitmagnetGraphql(jsonDecode(_gqlSample) as Map<String, dynamic>),
        parseTorznabXml(_torznabSample),
        parseGenericHtml(_htmlSample),
      ]) {
        for (final r in it) {
          expect(r.title.trim(), isNotEmpty);
        }
      }
    });
  });
}
