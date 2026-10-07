// 原生绑定单元冒烟：不依赖窗口，直接验证 FFI 导出面
// （widget 测试待 P0 页面成型后补充）
//
// 打 `native` 标签：需要 hub_native.dll 就位，CI 先构建原生模块再跑；
// 纯逻辑用例（无 dll）走 `.tools/*_check.dart` 纯 Dart 脚本。
@Tags(<String>['native'])
library;

import 'dart:convert';
import 'dart:io';
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

  // ---- 媒体扫描：hub_media_scan 导出面 ----
  // 这一层此前没有用例守：纯 Dart 护栏 media_scan_check 按设计「DLL 缺失就跳过
  // native 分支」，而 native_bindings 这边也没提它 —— 等于 FFI 契约零覆盖。
  // 这里补的是**跨语言边界**的部分：两段式调用是否成立、JSON 形状、递归与
  // maxDepth 是否真的生效、失败是否如实抛错（而非返回空列表冒充「扫不到」）。
  group('hub_media_scan', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('hub_media_scan_test');
    });

    tearDown(() {
      // 清理失败不能让测试 fail：CI 偶发文件句柄占用时宁可逆来顺受
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    List<Map<String, dynamic>> scanDir({String? path, int maxDepth = 8}) {
      final json = native.hubMediaScan(path ?? root.path, maxDepth: maxDepth);
      expect(json, isNotEmpty);
      final decoded = jsonDecode(json);
      expect(decoded, isA<List<dynamic>>());
      return (decoded as List<dynamic>).map((dynamic e) {
        return (e as Map<dynamic, dynamic>).map<String, dynamic>(
          (dynamic k, dynamic v) => MapEntry<String, dynamic>(k as String, v),
        );
      }).toList();
    }

    test('命中视频并按扩展名过滤非视频', () {
      File('${root.path}/a.mkv').writeAsBytesSync(Uint8List(16));
      File('${root.path}/b.mp4').writeAsBytesSync(Uint8List(8));
      File('${root.path}/notes.txt').writeAsBytesSync(Uint8List(4));

      final got = scanDir();
      expect(got, hasLength(2));
      expect(
        got.map((Map<String, dynamic> e) => e['name']),
        containsAll(<Object>['a.mkv', 'b.mp4']),
      );
      // 关键：非白名单扩展名不得出现在结果里，否则媒体库会被字幕/封面污染
      expect(
        got.map((Map<String, dynamic> e) => e['name']),
        isNot(contains('notes.txt')),
      );
    });

    test('返回的 JSON 结构与 size/mtime 字段可用', () {
      File('${root.path}/c.mkv').writeAsBytesSync(Uint8List(24));
      final e = scanDir().single;
      expect(e['name'], 'c.mkv');
      expect(e['path'], contains('c.mkv'));
      expect(e['size'], 24, reason: 'size 必须是真实字节数');
      expect(e['mtime'], isA<int>());
      expect(e['depth'], 1, reason: '根目录内的文件深度为 1');
    });

    test('递归命中子目录，且 depth 随层级递增', () {
      final sub = Directory('${root.path}/sub')..createSync();
      Directory('${sub.path}/deeper').createSync();
      File('${sub.path}/deeper/d.mkv').writeAsBytesSync(Uint8List(8));

      final got = scanDir();
      expect(got, hasLength(1));
      expect(got.single['depth'], 3, reason: 'root=0，每下一层 +1');
      expect(got.single['path'] as String, contains('/sub/deeper/'));
    });

    test('maxDepth 上限真的生效，越界层级不收录', () {
      final deep = Directory('${root.path}/d1/d2')..createSync(recursive: true);
      File('${deep.path}/skipped.mkv').writeAsBytesSync(Uint8List(8));
      File('${root.path}/kept.mkv').writeAsBytesSync(Uint8List(8));

      // maxDepth=1：只收根目录内的文件，子目录不再下探
      final names = scanDir(maxDepth: 1)
          .map((Map<String, dynamic> e) => e['name'])
          .toList();
      expect(names, <Object>['kept.mkv']);
      expect(names, isNot(contains('skipped.mkv')));
    });

    test('空根目录直接拒绝，不进 FFI', () {
      expect(
        () => native.hubMediaScan(''),
        throwsA(anything),
        reason: '空路径必须在 Dart 侧就被拦下',
      );
    });

    test('根目录不存在时抛错，而不是返回空数组冒充「扫不到」', () {
      final missing = Directory('${root.path}/no_such_dir');
      expect(missing.existsSync(), isFalse);
      expect(
        () => native.hubMediaScan(missing.path),
        throwsA(anything),
        reason: 'IO 失败必须如实抛错，网关据此降级到 Dart 回退',
      );
    });
  });
}
