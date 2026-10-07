// 媒体扫描护栏（ADR-0002 / M 批次）
//
// 覆盖两块可离线验的逻辑：
//   1. Dart 回退的多级递归扫描（LocalVideoScanner.scan(recursive: true)）
//      —— 递归命中、扩展名过滤、跳过隐藏/系统目录、深度上限、条数上限、排序
//   2. 原生 hub_media_scan 的两段式契约（DLL 找得到才测，找不到打提示跳过）
//   3. 网关 scanMediaDirectory 的降级行为（backend 标注必须如实）
//
// 零依赖纯 Dart（只用 dart:io / dart:convert / dart:ffi + 已有的 package:ffi）。
// 用法（在 project/app/gui 下）：
//   dart .tools/media_scan_check.dart        ← 本机推荐（dart.exe 不能建子进程，见下）
//   dart run .tools/media_scan_check.dart    ← 需 native-assets 钩子建子进程，本机受限
// 注：`dart run` 在「dart.exe 无法创建子进程」的机器上会卡在 sqlite3 build hook，
// 这是本机环境限制（对所有 .tools 护栏一视同仁），不是本护栏的缺陷。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../lib/core/media/media_scan_gateway.dart';
import '../lib/core/native/hub_native_bindings.dart';
import '../lib/features/media/local_video_scanner.dart';

int _pass = 0;
int _fail = 0;
final List<String> _failures = <String>[];

void eq(Object? actual, Object? expected, String label) {
  if (actual == expected) {
    _pass++;
    print('  [ok]   $label -> $actual');
  } else {
    _fail++;
    _failures.add('$label：实际=$actual 期望=$expected');
    print('  [FAIL] $label -> 实际=$actual 期望=$expected');
  }
}

void ok(bool cond, String label) {
  if (cond) {
    _pass++;
    print('  [ok]   $label');
  } else {
    _fail++;
    _failures.add(label);
    print('  [FAIL] $label');
  }
}

bool _isSorted(List<String> xs) {
  for (var i = 1; i < xs.length; i++) {
    if (xs[i - 1].compareTo(xs[i]) > 0) return false;
  }
  return true;
}

/// 建一棵形状已知的样本树（分隔符用平台原生形态）
Directory _makeTree() {
  final Directory root = Directory.systemTemp.createTempSync('hub_scan_check');
  void touch(String rel, {int bytes = 16}) =>
      File(p.joinAll(<String>[root.path, ...p.split(rel)]))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(bytes, 0));

  touch('top.mp4', bytes: 1024);
  touch('z.mov', bytes: 512);
  touch('a/1.mp4');
  touch('a/b/2.mkv');
  touch('a/b/c/3.txt'); // 非视频 → 该被忽略
  touch('a/b/c/d/e/deep.mp4'); // 深度 6 → 只在够深时才收
  touch('.hidden/4.mp4'); // 隐藏目录 → 该被跳过
  touch(r'$RECYCLE.BIN/x.mp4'); // 回收站 → 该被跳过
  touch('System Volume Information/y.mp4'); // 系统目录 → 该被跳过
  return root;
}

LocalVideoFile _must(List<LocalVideoFile> xs, String name) =>
    xs.firstWhere((LocalVideoFile f) => f.name == name);

Future<void> main() async {
  print('== Dart 递归扫描（LocalVideoScanner.scan recursive:true）==');
  final Directory root = _makeTree();
  try {
    final List<LocalVideoFile> all = LocalVideoScanner.scan(
      root.path,
      recursive: true,
    );
    final List<String> names = all.map((LocalVideoFile f) => f.name).toList();
    eq(all.length, 5, '递归命中 5 段视频（实际 $names）');
    ok(names.contains('top.mp4'), '  含根目录 top.mp4');
    ok(names.contains('z.mov'), '  含根目录 z.mov（.mov 也认）');
    ok(names.contains('1.mp4'), '  含 a/1.mp4（第 2 层）');
    ok(names.contains('2.mkv'), '  含 a/b/2.mkv（第 3 层）');
    ok(names.contains('deep.mp4'), '  含 a/b/c/d/e/deep.mp4（第 6 层）');
    ok(!names.contains('3.txt'), '  扩展名过滤：排除 .txt');
    ok(!names.contains('4.mp4'), '  跳过以 . 开头的隐藏目录');
    ok(!names.contains('x.mp4'), r'  跳过 $RECYCLE.BIN');
    ok(!names.contains('y.mp4'), '  跳过 System Volume Information');
    ok(_isSorted(names), '  结果按文件名升序（实际 $names）');

    eq(_must(all, 'top.mp4').depth, 1, '  depth(top.mp4)=1');
    eq(_must(all, '1.mp4').depth, 2, '  depth(a/1.mp4)=2');
    eq(_must(all, '2.mkv').depth, 3, '  depth(a/b/2.mkv)=3');
    eq(_must(all, 'deep.mp4').depth, 6, '  depth(deep.mp4)=6');
    ok(_must(all, 'top.mp4').mtimeMs > 0, '  mtimeMs 取到真实修改时间');
    eq(_must(all, 'top.mp4').sizeBytes, 1024, '  sizeBytes 取到真实大小');
    ok(_must(all, 'top.mp4').uri.startsWith('file:///'), '  uri 为 file:/// 形态');

    // 深度上限
    final List<LocalVideoFile> shallow = LocalVideoScanner.scan(
      root.path,
      recursive: true,
      maxDepth: 3,
    );
    eq(shallow.length, 4, 'maxDepth=3 → 收 4 条（depth<=3）');
    ok(
      shallow.any((LocalVideoFile f) => f.name == 'deep.mp4') == false,
      '  maxDepth=3 截断第 6 层的 deep.mp4',
    );
    ok(
      shallow.any((LocalVideoFile f) => f.name == '2.mkv'),
      '  maxDepth=3 边界上的 2.mkv（depth=3）仍收',
    );

    // 条数上限
    eq(
      LocalVideoScanner.scan(root.path, recursive: true, max: 2).length,
      2,
      'max=2 截断生效',
    );
    // 跨层累计也不能越过 max：根目录只贡献 1 条、子目录有 6 条，max=4 时必须停在 4
    final Directory wide = Directory.systemTemp.createTempSync('hub_scan_wide');
    try {
      File(p.join(wide.path, 'one.mp4')).writeAsBytesSync(<int>[0]);
      final Directory sub = Directory(p.join(wide.path, 'w'))..createSync();
      for (var i = 0; i < 6; i++) {
        File(p.join(sub.path, 'w$i.mp4')).writeAsBytesSync(<int>[0]);
      }
      eq(
        LocalVideoScanner.scan(wide.path, recursive: true, max: 4).length,
        4,
        'max=4 跨层累计不越界（根 1 + 子目录 6）',
      );
    } finally {
      wide.deleteSync(recursive: true);
    }

    // 旧签名兼容：不递归
    final List<LocalVideoFile> flat = LocalVideoScanner.scan(root.path);
    eq(
      flat.length,
      2,
      '旧签名 scan(dir) 仍只扫一层（实际 ${flat.map((LocalVideoFile f) => f.name).toList()}）',
    );
    ok(flat.every((LocalVideoFile f) => f.depth == 1), '  不递归时 depth 恒为 1');
    ok(
      flat.any((LocalVideoFile f) => f.name == '1.mp4') == false,
      '  不递归时不含子目录里的 1.mp4',
    );

    // 异常输入
    ok(
      LocalVideoScanner.scan(
        p.join(root.path, '不存在的目录'),
        recursive: true,
      ).isEmpty,
      '目录不存在 → 空列表（不抛异常）',
    );
    ok(
      LocalVideoScanner.scan(
        p.join(root.path, 'top.mp4'),
        recursive: true,
      ).isEmpty,
      '传文件而不是目录 → 空列表',
    );

    print('== 网关 scanMediaDirectory ==');
    final MediaScanResult res = await scanMediaDirectory(root.path);
    ok(res.isNotEmpty, '网关返回非空结果');
    eq(res.length, 5, '  网关默认 maxDepth=8 → 5 条');
    ok(
      res.entries.any((MediaScanEntry e) => e.name == '2.mkv'),
      '  网关结果含深层目录里的 2.mkv',
    );
    ok(
      res.entries.every((MediaScanEntry e) => !e.path.contains('.hidden')),
      '  网关同样跳过隐藏目录',
    );
    ok(
      res.backend == 'native' || res.backend == 'dart',
      "  backend 标注合法（实际 ${res.backend}）",
    );
    final MediaScanResult empty = await scanMediaDirectory('');
    ok(empty.isEmpty, '空 root → 空结果（不抛异常）');
    eq(empty.backend, 'dart', '  空 root 的 backend 记为 dart');

    print('== 原生 hub_media_scan ==');
    await _nativeSection(root.path);
  } finally {
    root.deleteSync(recursive: true);
    ok(!root.existsSync(), '临时样本树已清理');
  }

  print('');
  print('──────────────────────────────');
  print('断言通过 $_pass 条，失败 $_fail 条（合计 ${_pass + _fail} 条）。');
  ok(_pass + _fail >= 25, '断言总数 >= 25（护栏覆盖度下限）');
  if (_failures.isNotEmpty) {
    print('失败明细：');
    for (final String f in _failures) {
      print('  - $f');
    }
  }
  if (_fail > 0) throw StateError('media_scan_check 失败 $_fail 条');
}

/// 原生段：DLL 找得到才真测；找不到（或加载失败）打提示跳过，不算失败。
Future<void> _nativeSection(String root) async {
  // 从脚本自身位置反推工程根：gui/.tools → gui → app → project
  final Directory toolsDir = File(Platform.script.toFilePath()).parent;
  final Directory projectDir = toolsDir.parent.parent.parent;
  final List<String> candidates = <String>[
    p.join(projectDir.path, '.cache', 'debug', 'hub_native.dll'),
    p.join(projectDir.path, '.cache', 'probe', 'hub_native.dll'),
  ];
  String? dllPath;
  for (final String c in candidates) {
    if (File(c).existsSync()) {
      dllPath = c;
      break;
    }
  }
  if (dllPath == null) {
    print('  [skip] 未在 ${candidates.join(' / ')} 找到 hub_native.dll，跳过原生段');
    print('         绑定层 hubMediaScan 同样不可用（DLL 不在 installDir/cwd）');
    return;
  }
  print('  [info] 直接加载 $dllPath 验证 C ABI');
  DynamicLibrary? lib;
  try {
    lib = DynamicLibrary.open(dllPath);
  } catch (e) {
    print('  [skip] 加载失败：$e');
    return;
  }

  // 旧版 dll 可能还没导出 hub_media_scan（没重新 lunch native）：
  // 护栏的职责是「暴露问题」而不是「环境没跟上就整个崩掉」，故降级为提示。
  final int Function(
    Pointer<Utf8>,
    int,
    int,
    Pointer<Uint8>,
    int,
    Pointer<Int32>,
  )
  fn;
  try {
    fn = lib
        .lookupFunction<
          Int32 Function(
            Pointer<Utf8>,
            Int32,
            Int32,
            Pointer<Uint8>,
            Int32,
            Pointer<Int32>,
          ),
          int Function(
            Pointer<Utf8>,
            int,
            int,
            Pointer<Uint8>,
            int,
            Pointer<Int32>,
          )
        >('hub_media_scan');
  } catch (e) {
    print('  [skip] 该 dll 未导出 hub_media_scan：$e');
    print('         先跑 ./lunch native 重新构建原生层再验这一段');
    return;
  }

  final Pointer<Utf8> cRoot = root.toNativeUtf8();
  final Pointer<Int32> outLen = malloc<Int32>();
  String json = '';
  try {
    outLen.value = 0;
    final int probe = fn(cRoot, 8, 2000, nullptr, 0, outLen);
    eq(probe, -4, '  第一段（out=null）返回 -4 BUFFER_TOO_SMALL');
    ok(outLen.value > 2, '  第一段回填所需容量 ${outLen.value}');
    final Pointer<Uint8> buf = malloc<Uint8>(outLen.value);
    try {
      final int r = fn(cRoot, 8, 2000, buf, outLen.value, outLen);
      eq(r, 0, '  第二段返回 0');
      json = buf.cast<Utf8>().toDartString();
    } finally {
      malloc.free(buf);
    }
  } finally {
    malloc.free(cRoot);
    malloc.free(outLen);
  }

  ok(json.startsWith('[') && json.endsWith(']'), '  输出是 JSON 数组');
  ok(!json.contains('\\'), '  path 统一正斜杠（JSON 内无反斜杠）');
  final List<MediaScanEntry> entries = <MediaScanEntry>[
    ...(jsonDecode(json) as List<Object?>).map(MediaScanEntry.fromJson),
  ];
  final List<String> names = entries.map((MediaScanEntry e) => e.name).toList();
  eq(entries.length, 5, '  原生命中 5 段（实际 $names）');
  ok(names.contains('2.mkv'), '  含深层 2.mkv');
  ok(!names.contains('3.txt'), '  排除 .txt');
  ok(!names.contains('4.mp4'), '  跳过隐藏目录');
  ok(!names.contains('x.mp4'), r'  跳过 $RECYCLE.BIN');
  ok(!names.contains('y.mp4'), '  跳过 System Volume Information');
  ok(
    entries.every((MediaScanEntry e) => e.path.contains('/')),
    '  所有 path 用正斜杠',
  );
  ok(entries.any((MediaScanEntry e) => e.depth == 6), '  存在 depth=6 的深层条目');
  ok(
    entries.every((MediaScanEntry e) => e.mtimeMs > 0),
    '  mtimeMs 全部 > 0（native 秒 → 网关 ×1000）',
  );

  // 深度上限也要在 native 侧生效
  final Pointer<Int32> len2 = malloc<Int32>();
  final Pointer<Uint8> buf2 = malloc<Uint8>(4096);
  try {
    len2.value = 4096;
    final int r = fn(cRoot, 3, 2000, buf2, 4096, len2);
    eq(r, 0, '  maxDepth=3 调用返回 0');
    final List<MediaScanEntry> shallow = <MediaScanEntry>[
      ...(jsonDecode(buf2.cast<Utf8>().toDartString()) as List<Object?>).map(
        MediaScanEntry.fromJson,
      ),
    ];
    eq(shallow.length, 4, '  native maxDepth=3 → 4 条');
  } finally {
    malloc.free(buf2);
    malloc.free(len2);
  }

  await _sessionSection(lib, root);

  // 绑定层：DLL 不在 installDir/cwd 时必然失败，这里只如实报告
  try {
    final String viaBinding = hubMediaScan(root, maxDepth: 8, maxFiles: 2000);
    ok(viaBinding.startsWith('['), '  绑定层 hubMediaScan 也可用');
  } catch (e) {
    print('  [skip] 绑定层 hubMediaScan 不可用（$e）—— 属预期，DLL 不在加载路径上');
  }
}

/// 会话式扫描段（v2.3）：start → pause/resume → 轮询到终态 → result → close。
/// 旧版 dll 未导出 hub_scan_* 时整段提示跳过，不算失败。
Future<void> _sessionSection(DynamicLibrary lib, String root) async {
  final int Function(Pointer<Utf8>, int, int) startFn;
  final int Function(int, Pointer<Uint8>, int, Pointer<Int32>) pollFn;
  final int Function(int, Pointer<Uint8>, int, Pointer<Int32>) resultFn;
  final int Function(int) pauseFn;
  final int Function(int) resumeFn;
  final int Function(int) cancelFn;
  final int Function(int) closeFn;
  try {
    startFn = lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Int32),
          int Function(Pointer<Utf8>, int, int)
        >('hub_scan_start');
    pollFn = lib
        .lookupFunction<
          Int32 Function(Int32, Pointer<Uint8>, Int32, Pointer<Int32>),
          int Function(int, Pointer<Uint8>, int, Pointer<Int32>)
        >('hub_scan_poll');
    resultFn = lib
        .lookupFunction<
          Int32 Function(Int32, Pointer<Uint8>, Int32, Pointer<Int32>),
          int Function(int, Pointer<Uint8>, int, Pointer<Int32>)
        >('hub_scan_result');
    pauseFn = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'hub_scan_pause',
    );
    resumeFn = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'hub_scan_resume',
    );
    cancelFn = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'hub_scan_cancel',
    );
    closeFn = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'hub_scan_close',
    );
  } catch (e) {
    print('  [skip] 该 dll 未导出 hub_scan_*（先跑 ./lunch native）：$e');
    return;
  }
  print('  == 会话式扫描（进度/暂停/取消）==');

  // 入参错误路径
  eq(startFn(nullptr, 8, 2000), -1, '  scan_start(null) → INVALID_ARG');
  eq(pauseFn(999999), -1, '  未知会话 pause → INVALID_ARG');
  eq(closeFn(999999), 0, '  close 幂等（未知 id 也返回 OK）');

  final Pointer<Utf8> cRoot = root.toNativeUtf8();
  final Pointer<Int32> len = malloc<Int32>();
  try {
    final int sid = startFn(cRoot, 8, 2000);
    ok(sid > 0, '  scan_start 返回会话 id -> $sid');

    // 暂停/恢复：小树可能瞬间完成，两态都合法，只要不挂死
    eq(pauseFn(sid), 0, '  pause 返回 0');
    eq(resumeFn(sid), 0, '  resume 返回 0');

    // 轮询到终态（最长 ~10s）
    String state = '';
    int files = 0;
    for (int i = 0; i < 200; i++) {
      len.value = 0;
      final int probe = pollFn(sid, nullptr, 0, len);
      ok(probe == -4, '  poll 第一段返回 BUFFER_TOO_SMALL（仅首轮断言）');
      final Pointer<Uint8> buf = malloc<Uint8>(len.value);
      try {
        final int r = pollFn(sid, buf, len.value, len);
        eq(r, 0, '  poll 第二段返回 0（仅首轮断言）');
        final Object? decoded = jsonDecode(buf.cast<Utf8>().toDartString());
        if (decoded is Map<String, Object?>) {
          state = decoded['state']?.toString() ?? '';
          files = decoded['files'] is int ? decoded['files'] as int : 0;
        }
      } finally {
        malloc.free(buf);
      }
      if (state != 'running' && state != 'paused') break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    eq(state, 'done', '  轮询到终态 done');
    eq(files, 5, '  进度 files=5');

    // result：两段式取数，与一段式同构
    len.value = 0;
    eq(resultFn(sid, nullptr, 0, len), -4, '  result 第一段返回 BUFFER_TOO_SMALL');
    final Pointer<Uint8> rbuf = malloc<Uint8>(len.value);
    try {
      eq(resultFn(sid, rbuf, len.value, len), 0, '  result 第二段返回 0');
      final List<MediaScanEntry> entries = <MediaScanEntry>[
        ...(jsonDecode(rbuf.cast<Utf8>().toDartString()) as List<Object?>).map(
          MediaScanEntry.fromJson,
        ),
      ];
      eq(entries.length, 5, '  会话结果 5 条（与一段式一致）');
      ok(
        entries.every((MediaScanEntry e) => e.path.contains('/')),
        '  会话 path 同样统一正斜杠',
      );
    } finally {
      malloc.free(rbuf);
    }

    // close 后 id 立即失效
    eq(closeFn(sid), 0, '  close 返回 0');
    len.value = 0;
    eq(pollFn(sid, nullptr, 0, len), -1, '  close 后 poll → INVALID_ARG');
  } finally {
    malloc.free(cRoot);
    malloc.free(len);
  }
}
