// 纯 Dart 复跑 session_classify_test.dart 的全部断言。
// 用途：本机 flutter_tester 被安全策略拦住时，用 Dart VM 等价验证纯函数逻辑。
import '../lib/core/network/qr_status.dart';

int _pass = 0;
int _fail = 0;

void check(QrKind actual, QrKind expected, String label) {
  if (actual == expected) {
    _pass++;
    print('  [ok]   $label -> ${actual.name}');
  } else {
    _fail++;
    print('  [FAIL] $label -> ${actual.name}，期望 ${expected.name}');
  }
}

void checkTrue(bool cond, String label) {
  if (cond) {
    _pass++;
    print('  [ok]   $label');
  } else {
    _fail++;
    print('  [FAIL] $label');
  }
}

void main() {
  print('== web 兼容端点 code 序列 ==');
  check(
    classifyQrStatus(<String, dynamic>{
      'state': false,
      'code': 90038,
      'message': '请扫描二维码',
    }).kind,
    QrKind.waiting,
    'code=90038 请扫描二维码',
  );

  final c39 = classifyQrStatus(<String, dynamic>{
    'state': false,
    'code': 90039,
    'message': '请确认登录',
  });
  check(c39.kind, QrKind.scanned, 'code=90039 请确认登录');
  checkTrue(c39.message == '请确认登录', 'code=90039 文案透出');

  final bad = classifyQrStatus(<String, dynamic>{
    'state': false,
    'code': 40199002,
    'message': '',
  });
  check(bad.kind, QrKind.expired, 'code=40199002');
  checkTrue(bad.message.isNotEmpty, 'code=40199002 必须给出可读文案');

  check(
    classifyQrStatus(<String, dynamic>{
      'state': false,
      'code': 77777,
      'message': '未知',
    }).kind,
    QrKind.waiting,
    '未知 code + state=false',
  );
  check(
    classifyQrStatus(<String, dynamic>{'state': false, 'code': 0}).kind,
    QrKind.waiting,
    '未知 code 无 message',
  );

  print('== 长轮询 data.status 权威口径 ==');
  QrStatus poll(int status) => classifyQrStatus(<String, dynamic>{
    'state': 1,
    'code': 0,
    'message': '',
    'data': <String, dynamic>{'msg': '', 'status': status, 'version': 'abc'},
  });
  check(poll(0).kind, QrKind.waiting, 'data.status=0');
  check(poll(1).kind, QrKind.scanned, 'data.status=1');
  check(poll(2).kind, QrKind.confirmed, 'data.status=2');
  check(poll(-1).kind, QrKind.expired, 'data.status=-1');
  check(poll(-2).kind, QrKind.rejected, 'data.status=-2');
  check(poll(9).kind, QrKind.waiting, '未知 data.status=9');
  check(poll(-9).kind, QrKind.waiting, '未知 data.status=-9');
  check(
    classifyQrStatus(<String, dynamic>{'state': 0, 'code': 0}).kind,
    QrKind.expired,
    'longpoll state 数字 0',
  );

  print('== 凭证与语义兜底 ==');
  check(
    classifyQrStatus(<String, dynamic>{
      'state': true,
      'data': <String, dynamic>{
        'cookie': <String, dynamic>{'UID': '123_abc', 'CID': 'c', 'SEID': 's'},
      },
    }).kind,
    QrKind.confirmed,
    'data.cookie 含 UID/CID',
  );
  checkTrue(
    classifyQrStatus(<String, dynamic>{
          'data': <String, dynamic>{
            'cookie': <String, dynamic>{'UID': '', 'CID': 'c'},
          },
        }).kind !=
        QrKind.confirmed,
    'cookie UID 为空不算 confirmed',
  );
  check(
    classifyQrStatus(<String, dynamic>{'state': false, 'message': '二维码已失效'})
        .kind,
    QrKind.expired,
    '文案含失效',
  );
  check(
    classifyQrStatus(<String, dynamic>{'state': false, 'message': '请在手机上确认登录'})
        .kind,
    QrKind.scanned,
    '文案含确认',
  );

  print('== 防误杀不变量 ==');
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
  var allSafe = true;
  for (final s in webShapes) {
    final k = classifyQrStatus(s).kind;
    if (k == QrKind.expired || k == QrKind.rejected) {
      allSafe = false;
      print('  [FAIL] 响应 $s 被误判为终态 ${k.name}');
    }
  }
  checkTrue(allSafe, '布尔 state=false 的响应永不被判 expired/rejected');
  check(classifyQrStatus(<String, dynamic>{}).kind, QrKind.waiting, '空 Map');

  print('== JSON 外壳解析 ==');
  checkTrue(
    parseQrJsonBody('{"state":false,"code":90039}')['code'] == 90039,
    'parseQrJsonBody 纯 JSON',
  );
  checkTrue(
    parseQrJsonBody('jQuery_1({"state":true,"data":{}})')['state'] == true,
    'parseQrJsonBody JSONP 外壳',
  );
  try {
    parseQrJsonBody('not json');
    checkTrue(false, '非法输入应抛 FormatException');
  } on FormatException {
    checkTrue(true, '非法输入抛 FormatException');
  }

  print('');
  print('----------------------------------------');
  print('通过 $_pass 条，失败 $_fail 条');
  if (_fail > 0) {
    print('!!! 存在失败断言，不得交付');
    throw StateError('assertion failed');
  }
  print('全部通过 ✅');
}
