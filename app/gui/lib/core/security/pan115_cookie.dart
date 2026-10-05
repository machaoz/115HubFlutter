/// 115 会话 cookie 的解析与校验 —— **零依赖纯 Dart**。
///
/// 【为什么单独成文件】本项目把「必须被验证的逻辑」放在零依赖纯函数层，
/// 这样在 `flutter_tester` 不可用的环境里也能用 `dart run .tools/session_cookie_check.dart`
/// 等纯 Dart 脚本复跑（与 `core/network/qr_status.dart` 同一模式）。
/// `session_vault.dart` import 了 flutter_riverpod 与原生绑定，无法被纯脚本引用。
library;

/// 解析 115 cookie 串 → 键值表，键名统一大写。
///
/// 官方在网页端与 App 端出现过 `UID`/`uid`、`SEID`/`seid` 两种写法，
/// 统一大写后调用方只需判断一种形态。
Map<String, String> parsePan115Cookie(String cookie) {
  final out = <String, String>{};
  for (final part in cookie.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    final key = part.substring(0, eq).trim().toUpperCase();
    final value = part.substring(eq + 1).trim();
    if (key.isEmpty) continue;
    out[key] = value;
  }
  return out;
}

/// 恢复凭证的最低门槛：UID / CID / SEID 三者都非空。
///
/// 缺任何一个都算「凭证残缺」—— 带着半截 cookie 去请求 115 只会得到一堆
/// 语义不明的 `state=false`，比重新扫码更难排查，所以宁可不恢复。
bool isValidPan115Cookie(String cookie) {
  final m = parsePan115Cookie(cookie);
  return (m['UID'] ?? '').isNotEmpty &&
      (m['CID'] ?? '').isNotEmpty &&
      (m['SEID'] ?? '').isNotEmpty;
}

/// 日志/UI 用的凭证摘要：**只报有无，绝不输出原文**
String describePan115Cookie(String cookie) {
  final m = parsePan115Cookie(cookie);
  String has(String k) => (m[k] ?? '').isEmpty ? '空' : '有';
  return 'uid=${has('UID')} cid=${has('CID')} seid=${has('SEID')}';
}
