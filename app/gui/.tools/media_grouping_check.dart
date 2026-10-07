// 纯 Dart 复跑媒体分组归类的全部断言（不依赖 flutter_test）。
// 覆盖 B1-3：同集电视剧/同系列电影聚合、集序、标签回落。
// 跑法：cd project/app/gui && dart .tools/media_grouping_check.dart
import 'dart:io' show exitCode;

import '../lib/core/media/media_grouping.dart';
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

MediaGroupItem item(String filename, {int size = 100, List<String>? hints}) {
  final info = MediaTitleParser.parse(filename, pathHints: hints);
  return MediaGroupItem(
    path: 'X:/media/$filename',
    name: filename,
    sizeBytes: size,
    info: info,
  );
}

void main() {
  print('== B1-3 用户实例：同剧 41 集（EP 风格文件名）==');
  final disguiser = <MediaGroupItem>[
    for (var i = 1; i <= 41; i++)
      item(
        '[伪装者].STV4-HD.The.Disguiser.2015.EP${i.toString().padLeft(2, '0')}.mkv',
      ),
  ];
  final g1 = groupMedia(disguiser);
  eq(g1.length, 1, '41 集聚合为 1 组');
  eq(g1.first.items.length, 41, '组内条目数');
  eq(g1.first.kind, MediaTitleKind.tv, '类型=剧集');
  eq(g1.first.subtitle, '共 41 集', '副标题含集数（未识别季）');
  eq(episodeLabel(g1.first.items.first), 'E01', '首集标签');
  eq(episodeLabel(g1.first.items.last), 'E41', '末集标签');
  eq(g1.first.items[9].info.episode, 10, '第 10 项集号=10（EP10）');

  print('== SxxEyy 风格 + 季排序 ==');
  final g2 = groupMedia(<MediaGroupItem>[
    item('Show.S02E01.Again.mkv'),
    item('Show.S01E02.Beginnings.mkv'),
    item('Show.S01E01.Pilot.mkv'),
  ]);
  eq(g2.length, 1, '同剧跨季聚合');
  eq(episodeLabel(g2.first.items[0]), 'S01E01', 'S01E01 排最前');
  eq(episodeLabel(g2.first.items[2]), 'S02E01', 'S02 排最后');
  eq(episodeSubtitle(g2.first.items[0]), 'Pilot', '单集名作副行');

  print('== 同电影多画质合并 ==');
  final g3 = groupMedia(<MediaGroupItem>[
    item('Oppenheimer.2023.1080p.BluRay.x264-G1.mkv'),
    item('Oppenheimer.2023.2160p.UHD.BluRay.x265-G2.mkv'),
  ]);
  eq(g3.length, 1, '同键聚合为 1 组');
  eq(g3.first.kind, MediaTitleKind.movie, '类型=电影');
  eq(g3.first.items.length, 2, '两个版本都在');
  eq(g3.first.title, 'Oppenheimer', '组标题');
  eq(g3.first.year, 2023, '组年份');

  print('== 不同作品不粘连 + 剧集排前 ==');
  final g4 = groupMedia(<MediaGroupItem>[
    item('Zootopia.2016.1080p.mkv'),
    item('Interstellar.2014.1080p.mkv'),
    item('Friends.S01E01.mkv'),
  ]);
  eq(g4.length, 3, '三部作品三组');
  eq(g4[0].kind, MediaTitleKind.tv, '剧集组排最前');
  eq(g4[1].title, 'Interstellar', '电影组按标题排序');
  eq(g4[2].title, 'Zootopia', '电影组按标题排序（后）');

  print('== 集号缺失回落：季内排末 ==');
  // 解析口径：文件名里 S01 单独出现（无集号）不进季号通道、S01 残留在标题，
  // 因此「同键但无集号」必须靠 pathHints 补季号（与 _seasonFromHints 行为一致）。
  const hints = <String>['Show Season 02', 'Show'];
  final g5 = groupMedia(<MediaGroupItem>[
    item('Show.mkv', hints: hints),
    item('Show.S02E02.mkv', hints: hints),
    item('Show.S02E01.mkv', hints: hints),
  ]);
  eq(g5.length, 1, '同键（同剧名同季）聚合');
  ok(
    g5.first.items.last.name == 'Show.mkv',
    '集号缺失项排组末（实际 ${g5.first.items.last.name}）',
  );
  ok(
    g5.first.items.first.info.episode == 1,
    'E01 排组首（实际 ${g5.first.items.first.name}）',
  );

  print('== 标签回落口径 ==');
  final onlyEp = item(' documentaries.E12.mkv');
  eq(episodeLabel(onlyEp), 'E12', '仅有集号 → E12');
  final noEp = item('Random.Name.2020.mkv');
  eq(episodeLabel(noEp), noEp.name, '无集号 → 回落文件名');

  print('== 空输入 ==');
  eq(groupMedia(const <MediaGroupItem>[]).length, 0, '空列表 → 空组');

  print('');
  print('合计：$_pass 通过 / $_fail 失败');
  if (_fail > 0) {
    for (final f in _failures) {
      print('  FAIL: $f');
    }
    exitCode = 1;
  }
}
