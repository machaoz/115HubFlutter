import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:magnetic115hub/core/network/pan115_files.dart';

/// P 批次 CI 用例：115 网盘列目录解析。
/// 本机 flutter_tester 被拦时的等价断言见 `.tools/pan115_files_check.dart`。
Pan115Listing _parse(String json) =>
    parsePan115FileList(jsonDecode(json) as Object?);

void main() {
  const String mixed = '''
{"state":true,"data":[
  {"cid":"111","n":"Movies"},
  {"cid":"222","n":"Series"},
  {"fid":"f1","n":"B.mkv","s":57280972800,"pc":"pc_mkv","ico":"mkv","iv":1,"play_long":7697},
  {"fid":"f2","n":"A.mp4","s":2097152,"pc":"pc_mp4","ico":"mp4","iv":1,"play_long":600},
  {"fid":"f3","n":"readme.txt","s":1024,"pc":"pc_txt","ico":"txt"}
]}
''';

  group('条目分类', () {
    test('目录的 fid 即 cid，且没有 pickcode', () {
      final n = _parse(mixed).nodes.first;
      expect(n.isDir, isTrue);
      expect(n.fid, '111');
      expect(n.pickcode, isEmpty);
      expect(n.canPlay, isFalse);
    });

    test('iv=1 判为视频并带出 pickcode/大小/时长', () {
      final n = _parse(mixed).nodes.firstWhere((e) => e.name == 'B.mkv');
      expect(n.isVideo, isTrue);
      expect(n.pickcode, 'pc_mkv');
      expect(n.sizeBytes, 57280972800);
      expect(n.playLongSec, 7697);
      expect(n.canPlay, isTrue);
    });

    test('非视频后缀不判为视频', () {
      final n = _parse(mixed).nodes.firstWhere((e) => e.name == 'readme.txt');
      expect(n.isVideo, isFalse);
    });

    test('iv 缺失时按扩展名兜底（大小写不敏感）', () {
      final listing = _parse(
        '{"state":true,"data":['
        '{"fid":"n1","n":"Upper.MKV","s":1,"pc":"p1"},'
        '{"fid":"n2","n":"Disc.iso","s":2,"pc":"p2","ico":"iso"},'
        '{"fid":"n3","n":"Zero.mp4","s":3,"pc":"p3","ico":"mp4","iv":0}'
        ']}',
      );
      final byName = <String, Pan115Node>{
        for (final n in listing.nodes) n.name: n,
      };
      expect(byName['Upper.MKV']!.isVideo, isTrue);
      expect(byName['Upper.MKV']!.ext, 'mkv');
      expect(byName['Disc.iso']!.isVideo, isFalse);
      expect(byName['Zero.mp4']!.isVideo, isTrue, reason: 'iv=0 但后缀命中白名单');
    });
  });

  group('排序', () {
    test('目录 → 视频 → 其他，同组按名称', () {
      final names = _parse(mixed).nodes.map((e) => e.name).toList();
      expect(names, <String>[
        'Movies',
        'Series',
        'A.mp4',
        'B.mkv',
        'readme.txt',
      ]);
    });
  });

  group('data 形态容错', () {
    test('data 为 Map 时探测 list / files 键', () {
      expect(
        _parse('{"state":true,"data":{"list":[{"cid":"9","n":"纪录片"}]}}')
            .nodes
            .length,
        1,
      );
      expect(
        _parse(
          '{"state":true,"data":{"files":[{"fid":"f","n":"a.webm","s":1,"pc":"p"}],'
          '"count":1,"total":42}}',
        ).total,
        42,
      );
    });
  });

  group('错误口径', () {
    test('errNo=990001 覆盖服务端「登录超时」误导文案', () {
      final r = _parse('{"state":false,"error":"登录超时，请重新登录。","errNo":990001}');
      expect(r.ok, isFalse);
      expect(r.message, '当前会话无该接口权限（115 按登录渠道分域鉴权）');
    });

    test('其他错误码带上 errNo', () {
      final r = _parse('{"state":false,"error":"操作过于频繁","errNo":2001}');
      expect(r.ok, isFalse);
      expect(r.message, '操作过于频繁（errNo=2001）');
    });

    test('空 data 是空态不是错误', () {
      final r = _parse('{"state":true,"data":[]}');
      expect(r.ok, isTrue);
      expect(r.nodes, isEmpty);
      expect(r.message, isEmpty);
    });

    test('畸形/非 JSON 响应收敛为 ok=false 而不抛异常', () {
      expect(parsePan115FileList(null).ok, isFalse);
      expect(parsePan115FileList('<html>429</html>').ok, isFalse);
    });
  });
}
