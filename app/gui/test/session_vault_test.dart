// 115 会话凭证库护栏
//
// 背景：凭证记忆是「便利」与「泄密」只隔一层的开关 ——
//   * 恢复时若只校验「cookie 非空」，残缺凭证（缺 CID/SEID）会被当成已登录，
//     之后所有 115 请求只会拿到语义不明的 state=false，比未登录更难排查；
//   * 凭证库不可用（DPAPI 失败 / 插件未注册 / 无密钥环）时若向上抛异常，
//     启动流程会被直接打断。
// 这两条都是「改一行就出事」的级别，固化为断言。
//
// 【红线】本文件只用假凭证串，且**不打印**任何 cookie 内容。

import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/core/security/session_vault.dart';

/// 假凭证（真实 UID/CID/SEID 长得像 `1234567_abc...`，这里只要非空）
const String kGoodCookie = 'UID=1111_fake; CID=2222_fake; SEID=3333_fake';

void main() {
  group('parsePan115Cookie', () {
    test('解析三个键，键名统一大写', () {
      final m = parsePan115Cookie('uid=a; CID=b; seid=c');
      expect(m['UID'], 'a');
      expect(m['CID'], 'b');
      expect(m['SEID'], 'c');
    });

    test('多余字段与空段落不影响主字段', () {
      final m = parsePan115Cookie('UID=a;; foo; CID=b; SEID=c; KID=d');
      expect(m['UID'], 'a');
      expect(m['SEID'], 'c');
      expect(m['KID'], 'd');
    });

    test('空串 / 无等号 → 空 Map', () {
      expect(parsePan115Cookie(''), isEmpty);
      expect(parsePan115Cookie('abc'), isEmpty);
    });
  });

  group('isValidPan115Cookie', () {
    test('UID+CID+SEID 齐全 → true', () {
      expect(isValidPan115Cookie(kGoodCookie), isTrue);
    });

    test('缺任一字段 → false（恢复时必须拒绝）', () {
      expect(isValidPan115Cookie('UID=a; CID=b'), isFalse);
      expect(isValidPan115Cookie('UID=a; SEID=c'), isFalse);
      expect(isValidPan115Cookie('CID=b; SEID=c'), isFalse);
    });

    test('字段存在但为空 → false', () {
      expect(isValidPan115Cookie('UID=; CID=b; SEID=c'), isFalse);
      expect(isValidPan115Cookie('UID=  ; CID=b; SEID=c'), isFalse);
    });

    test('空串 / 垃圾串 → false（不抛异常）', () {
      expect(isValidPan115Cookie(''), isFalse);
      expect(isValidPan115Cookie('not a cookie'), isFalse);
    });
  });

  group('SessionVault - 正常往返', () {
    test('save 后 restore 能取回同样内容', () async {
      final store = MemoryCredentialStore();
      final vault = SessionVault(store);
      final ok = await vault.save(
        const SessionCredential(
          cookie: kGoodCookie,
          uid: '99999',
          loginApp: 'wechatmini',
        ),
      );
      expect(ok, isTrue);

      final back = await vault.restore();
      expect(back, isNotNull);
      expect(back!.cookie, kGoodCookie);
      expect(back.uid, '99999');
      expect(back.loginApp, 'wechatmini');
      expect(back.isValid, isTrue);
    });

    test('key 固定且可预测（升级换包也要能找到老凭证）', () async {
      final store = MemoryCredentialStore();
      await SessionVault(store)
          .save(const SessionCredential(cookie: kGoodCookie, uid: '1'));
      expect(store.data.containsKey(SessionVault.cookieKey), isTrue);
      expect(store.data.containsKey(SessionVault.uidKey), isTrue);
      expect(store.data.containsKey(SessionVault.loginAppKey), isTrue);
    });

    test('clear 后 restore 返回 null', () async {
      final store = MemoryCredentialStore();
      final vault = SessionVault(store);
      await vault.save(const SessionCredential(cookie: kGoodCookie));
      await vault.clear();
      expect(store.data, isEmpty);
      expect(await vault.restore(), isNull);
    });
  });

  group('SessionVault - 残缺与故障', () {
    test('凭证缺字段 → 不写入（save 返回 false）', () async {
      final store = MemoryCredentialStore();
      final vault = SessionVault(store);
      expect(
        await vault.save(const SessionCredential(cookie: 'UID=a; CID=b')),
        isFalse,
      );
      expect(store.data, isEmpty);
    });

    test('库里是残缺凭证 → restore 返回 null 并顺手清掉', () async {
      final store = MemoryCredentialStore();
      store.data[SessionVault.cookieKey] = 'UID=only';
      store.data[SessionVault.uidKey] = '1';
      final vault = SessionVault(store);

      expect(await vault.restore(), isNull);
      expect(store.data, isEmpty, reason: '残缺凭证应被丢弃，避免每次启动重复尝试');
    });

    test('凭证库写失败 → save 返回 false 且**不抛异常**（内存登录仍然成立）', () async {
      final store = MemoryCredentialStore()..fail = true;
      final vault = SessionVault(store);
      expect(
        await vault.save(const SessionCredential(cookie: kGoodCookie)),
        isFalse,
      );
    });

    test('凭证库读失败 → restore 返回 null 且**不阻塞启动**', () async {
      final store = MemoryCredentialStore()..fail = true;
      expect(await SessionVault(store).restore(), isNull);
    });

    test('clear 遇故障也不抛异常', () async {
      final store = MemoryCredentialStore()..fail = true;
      await expectLater(SessionVault(store).clear(), completes);
    });
  });

  group('SessionCredential', () {
    test('isValid 由 cookie 决定', () {
      expect(const SessionCredential(cookie: kGoodCookie).isValid, isTrue);
      expect(const SessionCredential(cookie: '').isValid, isFalse);
    });
  });
}
