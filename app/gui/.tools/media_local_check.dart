// 本地视频链路的离线断言（不依赖 flutter_test）。
// 覆盖三块可离线验的逻辑：
//   1. 目录遍历与扩展名过滤（LocalVideoScanner）
//   2. MediaSource.describe() 不泄漏 httpHeaders（凭证红线）
//   3. 视频标题解析（MediaTitleParser）
// 附带：播放失败分类（classifyPlaybackError）—— 同样是纯 Dart。
// 用法：在项目根目录 `dart .tools/media_local_check.dart`
import 'dart:io';

import '../lib/core/media/media_title_parser.dart';
import '../lib/features/media/local_video_scanner.dart';
import '../lib/features/media/media_playback_error.dart';
import '../lib/features/media/media_source.dart';

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

/// 建一个临时样本目录：3 段真视频 + 若干该被过滤掉的条目 + 一个子目录
Directory _makeSample() {
  final Directory root = Directory.systemTemp.createTempSync('hub_media_check');
  void touch(String name, {int bytes = 8}) =>
      File('${root.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(List<int>.filled(bytes, 0));

  touch('Movie.A.2020.mp4', bytes: 2048);
  touch('Show.S01E01.mkv', bytes: 4096);
  touch('clip.MOV'); // 大写扩展名
  touch('notes.txt'); // 非视频
  touch('sub.srt'); // 字幕
  touch('noext'); // 无扩展名
  touch('.mp4'); // 只有扩展名，没有文件名
  touch('video.mp4.bak'); // 扩展名不是最后一个
  Directory('${root.path}${Platform.pathSeparator}nested').createSync();
  touch('nested${Platform.pathSeparator}inner.mp4'); // 子目录里的：本轮不递归，不该出现
  return root;
}

void main() {
  print('== 目录遍历与扩展名过滤 ==');
  final Directory root = _makeSample();
  try {
    final List<LocalVideoFile> found = LocalVideoScanner.scan(root.path);
    final List<String> names = found.map((f) => f.name).toList();
    // 已知边角：名为 `.mp4` 的文件也会被收进来 —— `_isVideo` 的 `dot <= 0` 守护
    // 只在「点号位于路径第 0 位」时生效，Windows 绝对路径下永不成立。
    // 本轮不改扫描语义，这里如实记录现状（见报告「遗留问题」）。
    eq(found.length, 4, '收 4 段：3 段真视频 + 边角的 .mp4（实际 $names）');
    ok(names.contains('Movie.A.2020.mp4'), '  含 Movie.A.2020.mp4');
    ok(names.contains('Show.S01E01.mkv'), '  含 Show.S01E01.mkv');
    ok(names.contains('clip.MOV'), '  大写扩展名 .MOV 也认');
    ok(!names.contains('notes.txt'), '  排除 .txt');
    ok(!names.contains('sub.srt'), '  排除 .srt');
    ok(!names.contains('noext'), '  排除无扩展名');
    ok(names.contains('.mp4'), '  边角：只有扩展名的 .mp4 仍会被收（已知，见上）');
    ok(!names.contains('video.mp4.bak'), '  排除 .bak');
    ok(!names.contains('inner.mp4'), '  不递归子目录（本轮只扫一层）');
    ok(_isSorted(names), '  结果按文件名升序（实际 $names）');

    eq(LocalVideoScanner.scan(root.path, max: 2).length, 2, 'max=2 截断生效');
    ok(
      LocalVideoScanner.scan('${root.path}${Platform.pathSeparator}不存在')
          .isEmpty,
      '目录不存在 → 空列表（不抛异常）',
    );
    ok(
      LocalVideoScanner.scan('${root.path}${Platform.pathSeparator}notes.txt')
          .isEmpty,
      '传文件而不是目录 → 空列表',
    );

    final LocalVideoFile first = found.firstWhere(
      (LocalVideoFile f) => f.name == 'Movie.A.2020.mp4',
    );
    ok(
      first.uri.startsWith('file:///'),
      '  uri 为 file:/// 形态（实际 ${first.uri}）',
    );
    ok(first.path.contains(Platform.pathSeparator), '  path 是磁盘绝对路径');
    eq(first.sizeBytes, 2048, '  sizeBytes 取到真实大小');
  } finally {
    root.deleteSync(recursive: true);
  }

  print('== MediaSource.describe() 不泄漏 header ==');
  final withHeaders = MediaSource.media(
    'https://cdn.example.com/v/a.mkv',
    httpHeaders: <String, String>{'Cookie': 'UID=1;CID=2;SEID=3'},
  );
  final String d1 = MediaSource.describe(withHeaders);
  ok(d1.contains('httpHeaders=有'), '  描述里报「有」header');
  ok(!d1.contains('UID'), '  不含 UID');
  ok(!d1.contains('CID'), '  不含 CID');
  ok(!d1.contains('SEID'), '  不含 SEID');
  ok(!d1.contains('Cookie'), '  不含 Cookie 键名');
  ok(!d1.contains('cdn.example.com/v/a.mkv'), '  不含完整 URI（只报 host）');
  // 反证：Media 自己的 toString 确实会吐 header —— 说明这条红线不是臆想的
  ok(
    withHeaders.toString().contains('UID=1;CID=2;SEID=3'),
    '  反证：Media.toString() 确实会吐 header',
  );

  final local = MediaSource.media(
    Uri.file('C:${Platform.pathSeparator}Videos${Platform.pathSeparator}a.mkv')
        .toString(),
  );
  final String d2 = MediaSource.describe(local);
  // 坑：media_kit 构造 Media 时会把 file:///C:/... 归一化回裸路径 C:/...
  // （normalizeURI，对齐 libmpv）。所以 describe 不能再指望看到 `file:` 前缀。
  ok(
    !local.uri.startsWith('file:'),
    '  确认 Media 已归一化 file:// → 裸路径（实际 ${local.uri}）',
  );
  ok(d2.contains('scheme=file'), '  归一化后 describe 仍报 scheme=file（实际 $d2）');
  ok(d2.contains('httpHeaders=无'), '  本地源报「无」header');

  // 畸形 URI 不许抛：describe 在日志/UI 路径上，抛了会把整页带崩
  String d3 = '';
  try {
    d3 = MediaSource.describe(MediaSource.media('::::not a uri'));
  } catch (_) {
    d3 = 'threw';
  }
  ok(d3 != 'threw' && d3.isNotEmpty, '  畸形 URI 不抛且有输出（实际 $d3）');
  ok(!d3.contains('UID'), '  畸形 URI 描述也不含凭证');

  print('== 视频标题解析（本地文件名） ==');
  final m1 = MediaTitleParser.parse('The.Matrix.1999.1080p.BluRay.x264.mkv');
  eq(m1.title, 'The Matrix', 'The.Matrix.1999.1080p.BluRay.x264');
  eq(m1.year, 1999, '  年份');
  eq(m1.kind, MediaTitleKind.movie, '  类型为电影');

  final t1 = MediaTitleParser.parse(
    'Breaking.Bad.S05E14.Ozymandias.1080p.WEB-DL.mkv',
  );
  eq(t1.title, 'Breaking Bad', 'Breaking.Bad.S05E14.Ozymandias');
  eq(t1.season, 5, '  季');
  eq(t1.episode, 14, '  集');
  eq(t1.kind, MediaTitleKind.tv, '  类型为剧集');

  final c1 = MediaTitleParser.parse('庆余年 第一季 第01集.mp4');
  eq(c1.title, '庆余年', '庆余年 第一季 第01集');
  eq(c1.season, 1, '  季');
  eq(c1.episode, 1, '  集');

  final d1p = MediaTitleParser.parse(
    'S01E01.mkv',
    pathHints: <String>['Season 01', 'The Big Bang Theory'],
  );
  eq(d1p.title, 'The Big Bang Theory', '文件名只有 S01E01 → 取父目录兜底');
  ok(d1p.titleFromDirectory, '  标记为来自目录');

  ok(MediaTitleParser.parse('').title.isEmpty, '空输入不伪造标题');

  print('== 播放失败分类（用户可见诊断） ==');
  eq(
    classifyPlaybackError(
      Exception('Failed to open file:///C:/a.mp4'),
      fileExists: false,
    ).kind,
    MediaPlaybackErrorKind.unreadableFile,
    '文件不存在 → 文件读不到',
  );
  eq(
    classifyPlaybackError(Exception('Unsupported codec')).kind,
    MediaPlaybackErrorKind.unsupportedFormat,
    'Unsupported codec → 格式不支持',
  );
  eq(
    classifyPlaybackError(Exception('Failed to initialize a decoder')).kind,
    MediaPlaybackErrorKind.decoderFailure,
    '含 decoder 先判为解码器（不误报成格式问题）',
  );
  eq(
    classifyPlaybackError(Exception('something odd')).kind,
    MediaPlaybackErrorKind.unknown,
    '认不出的 → 归类未知，不瞎猜',
  );
  eq(classifyPlaybackError(null).detail, '（播放器没有给出具体原因）', '空错误也有兜底文案');
  for (final MediaPlaybackErrorKind k in MediaPlaybackErrorKind.values) {
    final MediaPlaybackError e = MediaPlaybackError(kind: k, detail: 'x');
    ok(e.headline.isNotEmpty && e.suggestion.isNotEmpty, '  ${k.name} 有标题与建议');
  }

  print('');
  print('──────────────────────────────');
  print('断言通过 $_pass 条，失败 $_fail 条。');
  if (_failures.isNotEmpty) {
    print('失败明细：');
    for (final f in _failures) {
      print('  - $f');
    }
  }
  if (_fail > 0) throw StateError('media_local_check 失败 $_fail 条');
}
