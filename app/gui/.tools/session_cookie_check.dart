// 纯 Dart 复跑「115 凭证解析/校验」护栏（对应 test/session_vault_test.dart 的纯函数部分）。
//
// 用途：本机 flutter_tester 被安全策略拦住时，用 Dart VM 等价验证。
// 运行：cd app/gui && dart run .tools/session_cookie_check.dart
//
// 为什么能纯 Dart 跑：`lib/core/security/pan115_cookie.dart` 刻意零依赖
// （不 import flutter / 原生绑定），所以这里直接 import 源码断言。
//
// 【红线】本文件只用假凭证串，且不打印任何 cookie 内容。
import '../lib/core/security/pan115_cookie.dart';

int _pass = 0;
int _fail = 0;

void checkEq(Object? actual, Object? expected, String label) {
  if ('$actual' == '$expected') {
    _pass++;
    print('  [ok]   $label');
  } else {
    _fail++;
    print('  [FAIL] $label -> $actual，期望 $expected');
  }
}

void check(bool ok, String label) {
  if (ok) {
    _pass++;
    print('  [ok]   $label');
  } else {
    _fail++;
    print('  [FAIL] $label');
  }
}

const String _good = 'UID=1111_fake; CID=2222_fake; SEID=3333_fake';

void main() {
  print('— parsePan115Cookie —');
  final m = parsePan115Cookie('uid=a; CID=b; seid=c');
  checkEq(m['UID'], 'a', '键名统一大写（uid→UID）');
  checkEq(m['CID'], 'b', 'CID 保持');
  checkEq(m['SEID'], 'c', '键名统一大写（seid→SEID）');

  final noisy = parsePan115Cookie('UID=a;; foo; CID=b; SEID=c; KID=d');
  checkEq(noisy['UID'], 'a', '空段落不影响');
  checkEq(noisy['SEID'], 'c', '多余字段不影响主字段');
  checkEq(noisy['KID'], 'd', '额外键保留');

  check(parsePan115Cookie('').isEmpty, '空串 → 空 Map');
  check(parsePan115Cookie('abc').isEmpty, '无等号 → 空 Map');
  check(parsePan115Cookie('=v').isEmpty, '等号在首位 → 忽略');
  checkEq(parsePan115Cookie('UID = a ; CID = b').length, 2, '键值两侧空格被裁剪');

  print('— isValidPan115Cookie（恢复凭证的门槛）—');
  check(isValidPan115Cookie(_good), 'UID+CID+SEID 齐全 → true');
  check(!isValidPan115Cookie('UID=a; CID=b'), '缺 SEID → false');
  check(!isValidPan115Cookie('UID=a; SEID=c'), '缺 CID → false');
  check(!isValidPan115Cookie('CID=b; SEID=c'), '缺 UID → false');
  check(!isValidPan115Cookie('UID=; CID=b; SEID=c'), 'UID 空值 → false');
  check(!isValidPan115Cookie('UID=  ; CID=b; SEID=c'), 'UID 全空格 → false');
  check(!isValidPan115Cookie(''), '空串 → false（不抛异常）');
  check(!isValidPan115Cookie('not a cookie'), '垃圾串 → false（不抛异常）');

  print('— describePan115Cookie：只报有无，绝不输出原文 —');
  final desc = describePan115Cookie(_good);
  checkEq(desc, 'uid=有 cid=有 seid=有', '三项齐全的描述');
  check(!desc.contains('1111_fake'), '描述不含凭证原文');
  check(!describePan115Cookie('UID=a').contains('a'), '半截凭证也不泄露原文');
  checkEq(
    describePan115Cookie('UID=a; CID=b'),
    'uid=有 cid=有 seid=空',
    '缺项显示「空」',
  );

  print('');
  print('session_cookie_check: $_pass passed, $_fail failed');
  if (_fail > 0) {
    throw StateError('session_cookie_check 未通过：$_fail 条断言失败');
  }
}
