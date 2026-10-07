// 纯 Dart 复跑媒体标题解析的全部断言（不依赖 flutter_test）。
// 用途：本机 dart 无法在带 pubspec 的工程里 spawn 时，把本文件与
// lib/core/media/media_title_parser.dart 一起复制到无 pubspec 的临时目录再跑。
import '../lib/core/media/media_title_parser.dart';

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

MediaTitleInfo p(String s, {List<String>? hints}) =>
    MediaTitleParser.parse(s, pathHints: hints);

void main() {
  print('== 英文电影：技术标签剔除 ==');
  final m1 = p('The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv');
  eq(m1.title, 'The Matrix', 'The.Matrix.1999.1080p.BluRay.x264-GROUP');
  eq(m1.year, 1999, '  年份');
  eq(m1.kind, MediaTitleKind.movie, '  类型');
  eq(m1.resolution, '1080p', '  分辨率');
  eq(m1.source, 'bluray', '  片源');
  eq(m1.videoCodec, 'x264', '  视频编码');
  eq(m1.releaseGroup, 'GROUP', '  压制组');
  ok(m1.confidence >= 0.6, '  自信度 >= 0.6（实际 ${m1.confidence}）');

  final m2 = p(
    'Interstellar.2014.2160p.UHD.BluRay.x265.HDR10.Atmos-TERMiNAL.mkv',
  );
  eq(m2.title, 'Interstellar', 'Interstellar 4K HDR 长串');
  eq(m2.year, 2014, '  年份');
  eq(m2.videoCodec, 'x265', '  编码 x265');
  eq(m2.hdr, 'hdr10', '  HDR 标记');
  eq(m2.audioCodec, 'atmos', '  音轨 Atmos');

  // 复合音轨标签不能被切碎后残留孤立数字（`DDP5.1` 曾残留成标题里的 "1"）
  final m3 = p('Tenet.2020.1080p.WEB-DL.DDP5.1.H.264-CMRG.mkv');
  eq(m3.title, 'Tenet', 'DDP5.1.H.264-CMRG 复合音轨');
  eq(m3.year, 2020, '  年份');

  print('== 英文剧集：季集截断与单集名 ==');
  final t1 = p('Breaking.Bad.S05E14.Ozymandias.1080p.WEB-DL.mkv');
  eq(t1.title, 'Breaking Bad', 'Breaking.Bad.S05E14.Ozymandias');
  eq(t1.season, 5, '  季');
  eq(t1.episode, 14, '  集');
  eq(t1.episodeTitle, 'Ozymandias', '  单集名');
  eq(t1.kind, MediaTitleKind.tv, '  类型');

  final t2 = p('The.Office.US.S09E01.720p.HDTV.x264.mkv');
  eq(t2.title, 'The Office US', 'The.Office.US.S09E01');
  eq(t2.season, 9, '  季');
  eq(t2.episode, 1, '  集');

  final t3 = p('Friends.S01E01-E03.1080p.mkv');
  eq(t3.episode, 1, '多集合并 S01E01-E03 起始集');
  eq(t3.episodeEnd, 3, '  结束集');

  print('== 中文：无空格、中字标记、中文数字季集 ==');
  final c1 = p('权力的游戏.S01E01.1080p.mkv');
  eq(c1.title, '权力的游戏', '权力的游戏.S01E01');
  eq(c1.season, 1, '  季');
  eq(c1.episode, 1, '  集');

  final c2 = p('流浪地球.2019.BD.1080p.国语中字.mkv');
  eq(c2.title, '流浪地球', '流浪地球.2019.BD.1080p.国语中字');
  eq(c2.year, 2019, '  年份');
  ok(c2.languages.contains('国语'), '  语言含国语（实际 ${c2.languages}）');
  ok(c2.languages.contains('中字'), '  语言含中字');

  final c3 = p('庆余年 第一季 第01集.mp4');
  eq(c3.title, '庆余年', '庆余年 第一季 第01集（中文数字季）');
  eq(c3.season, 1, '  季（一 → 1）');
  eq(c3.episode, 1, '  集');
  eq(c3.kind, MediaTitleKind.tv, '  类型');

  final c4 = p('大明王朝1566 第十二集.mkv');
  eq(c4.episode, 12, '中文数字 第十二集 → 12');

  final c5 = p('我和我的祖国.1080p.WEB-DL.国配.mkv');
  eq(c5.title, '我和我的祖国', '无年份中文片');
  eq(c5.year, null, '  年份为空');

  print('== 中英双名：别名供 TMDB 多轮检索 ==');
  final a1 = p('蜘蛛侠：英雄无归.Spider-Man.No.Way.Home.2021.2160p.mkv');
  eq(a1.year, 2021, '中英双名年份');
  ok(a1.aliases.length >= 2, '别名 >= 2 条（实际 ${a1.aliases.length}）');
  ok(a1.aliases.any((e) => RegExp(r'[\u4e00-\u9fff]').hasMatch(e)), '  含中文别名');
  ok(a1.aliases.any((e) => e.contains('spider')), '  含英文别名');

  print('== 年份陷阱：片名里的数字不能被当成年份 ==');
  final y1 = p('2001太空漫游.1968.1080p.mkv');
  eq(y1.year, 1968, '2001太空漫游.1968（取靠后的年份）');
  eq(y1.title, '2001太空漫游', '  片名保留 2001');

  final y2 = p('Blade.Runner.2049.2017.1080p.mkv');
  eq(y2.year, 2017, 'Blade.Runner.2049.2017');
  eq(y2.title, 'Blade Runner 2049', '  片名保留 2049');

  print('== 动漫：括号压制组 + 尾缀集号 ==');
  final k1 = p('[VCB-Studio] Kimetsu no Yaiba - 01 [Ma10p_1080p].mkv');
  eq(k1.title, 'Kimetsu no Yaiba', '动漫 片名 - 01');
  eq(k1.episode, 1, '  尾缀集号');
  eq(k1.kind, MediaTitleKind.tv, '  类型');

  print('== 尾缀集号的误判防线 ==');
  final f1 = p('Movie.Name.Part.2.1080p.mkv');
  eq(f1.episode, null, 'Part.2 不能被判成第 2 集');
  eq(f1.kind, MediaTitleKind.movie, '  仍为电影');

  print('== 目录兜底 ==');
  final d1 = p(
    'S01E01.mkv',
    hints: <String>['Season 01', 'The Big Bang Theory'],
  );
  eq(d1.title, 'The Big Bang Theory', '文件名只有 S01E01 → 取父目录');
  ok(d1.titleFromDirectory, '  标记 titleFromDirectory');
  ok(d1.confidence < 0.6, '  自信度下调（实际 ${d1.confidence}）');

  final d2 = p(
    'S02E03.mkv',
    hints: <String>['Season 02', 'The Big Bang Theory'],
  );
  eq(d2.season, 2, '目录 Season 02 → 季');

  final d3 = p('E05.mkv', hints: <String>['动漫', '进击的巨人']);
  eq(d3.title, '进击的巨人', '跳过分类目录「动漫」');

  print('== 去重键 ==');
  final g1 = p('Movie.Name.2019.1080p.mkv');
  final g2 = p('Movie.Name.2019.2160p.mkv');
  eq(g1.contentKey, g2.contentKey, '同片不同画质 → 同一作品键');
  eq(g1.contentKey, 'movie|movie name|2019', '  作品键格式');

  final g3 = p('Friends.S01E01.mkv');
  final g4 = p('Friends.S01E02.mkv');
  eq(g3.contentKey, g4.contentKey, '同剧不同集 → 同一作品键');
  ok(g3.episodeKey != g4.episodeKey, '  单集键不同');

  print('== 视频文件判定 ==');
  ok(MediaTitleParser.isVideoFile('a.MKV'), '大写扩展名 MKV');
  ok(MediaTitleParser.isVideoFile('a.mkv'), 'mkv');
  ok(!MediaTitleParser.isVideoFile('a.nfo'), 'nfo 不是视频');
  ok(!MediaTitleParser.isVideoFile('a.srt'), 'srt 不是视频');
  ok(!MediaTitleParser.isVideoFile('noext'), '无扩展名不是视频');

  print('== 退化输入：不许崩，也不许伪造标题 ==');
  final e1 = p('1080p.mkv');
  ok(!e1.worthMatching, '纯噪声不值得去请求 TMDB');
  final e2 = p('');
  eq(e2.title, '', '空输入');
  final e3 = p('.mkv');
  eq(e3.title, '', '只有扩展名');
  final e4 = p('D:\\Media\\Movies\\Inception.2010.mkv');
  eq(e4.title, 'Inception', 'Windows 绝对路径');
  final e5 = p('/mnt/media/Inception.2010.mkv');
  eq(e5.title, 'Inception', 'Unix 路径');

  print('== 未闭合括号不许吞掉片名 ==');
  final b1 = p('The Matrix [1999.mkv');
  ok(b1.title.contains('Matrix'), '未闭合括号仍保留片名（实际 ${b1.title}）');

  print('');
  print('──────────────────────────────');
  print('断言通过 $_pass 条，失败 $_fail 条。');
  if (_failures.isNotEmpty) {
    print('失败明细：');
    for (final f in _failures) {
      print('  - $f');
    }
  }
  if (_fail > 0) throw StateError('media_title_check 失败 $_fail 条');
}
