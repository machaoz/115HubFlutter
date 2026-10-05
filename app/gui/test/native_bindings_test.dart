// 原生绑定单元冒烟：不依赖窗口，直接验证 FFI 导出面
// （widget 测试待 P0 页面成型后补充）
//
// 打 `native` 标签：需要 hub_native.dll 就位，CI 先构建原生模块再跑；
// 纯逻辑用例（无 dll）走 `.tools/*_check.dart` 纯 Dart 脚本。
@Tags(<String>['native'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/core/native/hub_native_bindings.dart' as native;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hub_native 可从应用目录或工作目录加载', () {
    expect(native.hubNativeAvailable, isTrue);
  });

  test('hub_version 返回非空版本串', () {
    final v = native.hubVersion();
    expect(v, isNotEmpty);
    expect(v, contains('abi'));
  });

  test('hub_self_check 能力位：baselib/network/system 至少三位齐备', () {
    final bits = native.hubSelfCheck();
    expect(bits & 0x01, 0x01);
    expect(bits & 0x02, 0x02);
    expect(bits & 0x04, 0x04);
  });

  test('magnet 解析返回 40 位 infohash', () {
    final h = native.hubParseMagnetInfohash(
      'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=test',
    );
    expect(h, '0123456789abcdef0123456789abcdef01234567');
  });

  test('非法 magnet 抛错', () {
    expect(
      () => native.hubParseMagnetInfohash('not-a-magnet'),
      throwsA(anything),
    );
  });

  test('host 限流第二次必须等待', () {
    expect(native.hubNetRateAcquire('smoke.test'), 0);
    expect(native.hubNetRateAcquire('smoke.test'), greaterThan(0));
  });

  // ---- 系统级密钥保护（DPAPI）：验证 Dart 侧 FFI 编排（两段式容量查询）----
  // C++ 侧往返已由 hub_native_smoke 覆盖；这里补的是「Dart 内存/长度换算是否正确」。
  test('hub_secret_backend 在 Windows 上返回 dpapi', () {
    expect(native.hubSecretBackend(), 'dpapi');
  });

  test('hub_secret DPAPI 加密→解密往返，且篡改必失败', () {
    final plain = Uint8List.fromList(utf8.encode('UID=a; CID=b; SEID=c'));
    final blob = native.hubSecretProtect(plain);
    expect(blob, isNotNull, reason: 'DPAPI 加密不应失败');
    expect(blob!.length, greaterThan(plain.length));
    expect(blob, isNot(equals(plain)), reason: '密文不得等于明文');

    final back = native.hubSecretUnprotect(blob);
    expect(back, isNotNull);
    expect(back, equals(plain), reason: '往返必须与原明文一致');

    final tampered = Uint8List.fromList(blob);
    tampered[tampered.length - 1] ^= 0xFF;
    expect(
      native.hubSecretUnprotect(tampered),
      isNull,
      reason: '篡改的密文必须拒绝，不得返回脏数据',
    );

    expect(native.hubSecretProtect(Uint8List(0)), isNull, reason: '空输入拒绝');
    expect(native.hubSecretUnprotect(Uint8List(0)), isNull, reason: '空密文拒绝');
  });
}
