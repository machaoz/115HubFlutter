// 115 扫码登录状态码映射回归护栏
//
// 背景（2026-09-16 事故）：`_classify` 曾用 `state == false` 覆盖「失效」语义，
// 于是服务端表示「已扫码、请在手机上确认」的 code=90039 被判成 expired ——
// 用户刚扫完码，客户端就把登录流程掐死，手机上点确认再也没人来收。
//
// 这类「第三方接口悄悄新增一个中间态」的变化无法靠 review 发现，
// 只能把真值表固化成断言。任何一行映射发生变化，都必须回到这里同步更新，
// 并同步更新 `lib/core/network/qr_status.dart` 末尾的真值表注释。

import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/core/network/qr_status.dart';

void main() {
  group('classifyQrStatus - web 兼容端点 code 序列', () {
    test('code=90038「请扫描二维码」→ waiting', () {
      final st = classifyQrStatus(<String, dynamic>{
        'state': false,
        'code': 90038,
        'message': '请扫描二维码',
      });
      expect(st.kind, QrKind.waiting);
    });

    // ★ 本次事故的核心护栏，任何时候都不要删这条
    test('code=90039「请确认登录」→ scanned（绝不能是 expired）', () {
      final st = classifyQrStatus(<String, dynamic>{
        'state': false,
        'code': 90039,
        'message': '请确认登录',
      });
      expect(st.kind, QrKind.scanned);
      expect(st.kind, isNot(QrKind.expired));
      expect(st.message, '请确认登录');
    });

    test('code=40199002 → expired', () {
      final st = classifyQrStatus(<String, dynamic>{
        'state': false,
        'code': 40199002,
        'message': '',
      });
      expect(st.kind, QrKind.expired);
      expect(st.message, isNotEmpty); // 必须给出可读文案
    });

    // ★ 第二道护栏：未知码不得判终态
    test('未知 code + state=false → waiting（不判终态）', () {
      final st = classifyQrStatus(<String, dynamic>{
        'state': false,
        'code': 77777,
        'message': '未知',
      });
      expect(st.kind, QrKind.waiting);
    });

    test('未知 code 且无 message → waiting', () {
      final st = classifyQrStatus(<String, dynamic>{'state': false, 'code': 0});
      expect(st.kind, QrKind.waiting);
    });
  });

  group('classifyQrStatus - 长轮询 data.status 权威口径', () {
    QrStatus poll(int status) => classifyQrStatus(<String, dynamic>{
      'state': 1,
      'code': 0,
      'message': '',
      'data': <String, dynamic>{'msg': '', 'status': status, 'version': 'abc'},
    });

    test('status=0 → waiting', () => expect(poll(0).kind, QrKind.waiting));
    test('status=1 → scanned', () => expect(poll(1).kind, QrKind.scanned));
    test('status=2 → confirmed', () => expect(poll(2).kind, QrKind.confirmed));
    test('status=-1 → expired', () => expect(poll(-1).kind, QrKind.expired));
    test('status=-2 → rejected', () => expect(poll(-2).kind, QrKind.rejected));

    test('未知 status → waiting（不判终态）', () {
      expect(poll(9).kind, QrKind.waiting);
      expect(poll(-9).kind, QrKind.waiting);
    });

    test('state 为数字 0（官方：二维码无效）→ expired', () {
      final st = classifyQrStatus(<String, dynamic>{'state': 0, 'code': 0});
      expect(st.kind, QrKind.expired);
    });
  });

  group('classifyQrStatus - 凭证与语义兜底', () {
    test('data.cookie 含 UID/CID → confirmed', () {
      final st = classifyQrStatus(<String, dynamic>{
        'state': true,
        'data': <String, dynamic>{
          'cookie': <String, dynamic>{
            'UID': '123_abc',
            'CID': 'c',
            'SEID': 's',
          },
        },
      });
      expect(st.kind, QrKind.confirmed);
    });

    test('cookie UID 为空 → 不算 confirmed', () {
      final st = classifyQrStatus(<String, dynamic>{
        'data': <String, dynamic>{
          'cookie': <String, dynamic>{'UID': '', 'CID': 'c'},
        },
      });
      expect(st.kind, isNot(QrKind.confirmed));
    });

    test('文案含「失效」→ expired', () {
      final st = classifyQrStatus(<String, dynamic>{
        'state': false,
        'message': '二维码已失效',
      });
      expect(st.kind, QrKind.expired);
    });

    test('文案含「确认」→ scanned', () {
      final st = classifyQrStatus(<String, dynamic>{
        'state': false,
        'message': '请在手机上确认登录',
      });
      expect(st.kind, QrKind.scanned);
    });
  });

  // 最强的一道护栏：**无论服务端吐什么花样，只要是布尔 state=false 的
  // web 端点响应，就不允许被判成 expired/rejected**（confirmed 由 cookie 另行判定）。
  group('classifyQrStatus - 防误杀不变量', () {
    final webShapes = <Map<String, dynamic>>[
      <String, dynamic>{'state': false},
      <String, dynamic>{'state': false, 'code': 90038},
      <String, dynamic>{'state': false, 'code': 90039},
      <String, dynamic>{'state': false, 'code': 90040},
      <String, dynamic>{'state': false, 'code': 1},
      <String, dynamic>{'state': false, 'code': -1},
      <String, dynamic>{'state': false, 'message': ''},
      <String, dynamic>{'state': false, 'message': '未知'},
      <String, dynamic>{'state': false, 'message': '请稍候'},
      <String, dynamic>{},
    ];

    test('布尔 state=false 的响应永不被判成 expired/rejected', () {
      for (final shape in webShapes) {
        final kind = classifyQrStatus(shape).kind;
        expect(
          kind,
          isNot(anyOf(QrKind.expired, QrKind.rejected)),
          reason: '响应 $shape 被误判为终态 $kind',
        );
      }
    });

    test('空 Map 也能安全归类（不抛异常）', () {
      expect(() => classifyQrStatus(<String, dynamic>{}), returnsNormally);
      expect(classifyQrStatus(<String, dynamic>{}).kind, QrKind.waiting);
    });
  });

  group('parseQrJsonBody - JSON 外壳', () {
    test('纯 JSON', () {
      final m = parseQrJsonBody('{"state":false,"code":90039}');
      expect(m['code'], 90039);
    });

    test('JSONP 外壳可剥离', () {
      final m = parseQrJsonBody('jQuery_1({"state":true,"data":{}})');
      expect(m['state'], true);
    });

    test('非法输入抛 FormatException，由调用方处理', () {
      expect(
        () => parseQrJsonBody('not json'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
