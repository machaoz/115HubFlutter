// 原生绑定单元冒烟：不依赖窗口，直接验证 FFI 导出面
// （widget 测试待 P0 页面成型后补充）
import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/core/native/hub_native_bindings.dart' as native;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
        'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=test');
    expect(h, '0123456789abcdef0123456789abcdef01234567');
  });

  test('非法 magnet 抛错', () {
    expect(() => native.hubParseMagnetInfohash('not-a-magnet'), throwsA(anything));
  });

  test('host 限流第二次必须等待', () {
    expect(native.hubNetRateAcquire('smoke.test'), 0);
    expect(native.hubNetRateAcquire('smoke.test'), greaterThan(0));
  });
}
