// P 批次护栏：115 网盘列目录解析（纯 Dart，不依赖 flutter_tester）。
//
// 用途：本机 `flutter test` 起不来时，用 Dart VM 直接复跑解析层的全部断言。
// 运行（两种都支持，工作目录 = project/app/gui）：
//   dart .tools/pan115_files_check.dart
//   dart run .tools/pan115_files_check.dart
import 'dart:convert';
import 'dart:io';

import '../lib/core/network/pan115_files.dart';

int _pass = 0;
int _fail = 0;

void checkEq(Object? actual, Object? expected, String label) {
  if ('$actual' == '$expected') {
    _pass++;
    print('  [ok]   $label -> $actual');
  } else {
    _fail++;
    print('  [FAIL] $label -> $actual，期望 $expected');
  }
}

void checkTrue(bool cond, String label) {
  if (cond) {
    _pass++;
    print('  [ok]   $label');
  } else {
    _fail++;
    print('  [FAIL] $label');
  }
}

/// JSON 字符串 → 已 decode 对象；畸形 JSON 返回 null（由调用方断言后续行为）
Object? decode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- fixtures

/// ① 混合：2 目录 + 2 视频（iv=1）+ 1 文本 + 1 图片（iv=0）
const String fxMixed = '''
{"state":true,"count":6,"total":6,"data":[
  {"cid":"111","n":"Movies"},
  {"cid":"222","n":"Series"},
  {"fid":"f1","n":"B.mkv","s":57280972800,"pc":"pc_mkv","ico":"mkv","iv":1,"play_long":7697},
  {"fid":"f2","n":"A.mp4","s":2097152,"pc":"pc_mp4","ico":"mp4","iv":1,"play_long":600},
  {"fid":"f3","n":"readme.txt","s":1024,"pc":"pc_txt","ico":"txt"},
  {"fid":"f4","n":"cover.jpg","s":2048,"pc":"pc_jpg","ico":"jpg","iv":0}
]}
''';

/// ② data 为 Map、条目在 `list` 键下
const String fxMapList = '''
{"state":true,"data":{"count":2,"list":[
  {"cid":"900","n":"纪录片"},
  {"fid":"f9","n":"Sample.mov","s":4096,"pc":"pc_mov","ico":"mov","iv":1}
]}}
''';

/// ③ data 为 Map、条目在 `files` 键下，且带 count/total
const String fxMapFiles = '''
{"state":true,"data":{"files":[
  {"fid":"f7","n":"Clip.webm","s":8192,"pc":"pc_webm","ico":"webm"}
],"count":1,"total":42}}
''';

/// ④ data 为 Map、条目再嵌一层 `data`（历史版本形态）
const String fxMapNested = '''
{"state":true,"data":{"data":[
  {"cid":"700","n":"动漫"}
]}}
''';

/// ⑤ 缺 iv：只能靠扩展名判定（含大写后缀与 iv=0 的反向用例）
const String fxNoIv = '''
{"state":true,"data":[
  {"fid":"n1","n":"Upper.MKV","s":1,"pc":"p1"},
  {"fid":"n2","n":"Live.ts","s":2,"pc":"p2","ico":"ts"},
  {"fid":"n3","n":"Disc.iso","s":3,"pc":"p3","ico":"iso"},
  {"fid":"n4","n":"NoExt","s":4,"pc":"p4"},
  {"fid":"n5","n":"Zero.mp4","s":5,"pc":"p5","ico":"mp4","iv":0}
]}
''';

/// ⑥ 鉴权域不通：990001（spike 实测的真实响应骨架）
const String fxAuth990001 = '''
{"state":false,"error":"登录超时，请重新登录。","errNo":990001,
 "errno":990001,"request":"/natsort/files.php?cid=0"}
''';

/// ⑦ 其他业务错误：带 errNo 与服务端文案
const String fxStateFalse = '''
{"state":false,"error":"操作过于频繁","errNo":2001}
''';

/// ⑧ 空目录：state=true 且 data 为空数组
const String fxEmpty = '{"state":true,"data":[]}';

/// ⑨ 畸形 JSON：jsonDecode 必然抛错
const String fxMalformed = '{"state":true,"data":[{"n":"掉了一半';

/// ⑩ 风控页：115 被限流时直接回 HTML
const String fxHtml =
    '<html><head><title>429 Too Many Requests</title></head></html>';

void main() {
  print('== 1. 混合目录：分类与字段 ==');
  final mixed = parsePan115FileList(decode(fxMixed));
  checkTrue(mixed.ok, 'state=true → ok=true');
  checkEq(mixed.nodes.length, 6, '条目总数');
  checkEq(mixed.count, 6, '顶层 count 透出');
  checkEq(mixed.total, 6, '顶层 total 透出');
  checkTrue(mixed.nodes[0].isDir, '首位是目录');
  checkTrue(mixed.nodes[1].isDir, '次位是目录');
  checkEq(mixed.nodes[0].fid, '111', '目录节点的 fid 即 cid');
  checkEq(mixed.nodes[0].name, 'Movies', '目录名');
  checkEq(mixed.nodes[0].pickcode, '', '目录没有 pickcode');
  checkTrue(mixed.nodes[0].canPlay == false, '目录不可取链');
  checkTrue(!mixed.nodes[2].isDir, '第三位是文件');
  checkTrue(mixed.nodes[2].isVideo, 'iv=1 → 视频');
  checkEq(mixed.nodes[2].pickcode, 'pc_mp4', '文件 pickcode');
  checkEq(mixed.nodes[2].sizeBytes, 2097152, '文件字节数');
  checkEq(mixed.nodes[2].playLongSec, 600, 'play_long 秒数');
  checkEq(mixed.nodes[2].ico, 'mp4', 'ico 字段');
  checkEq(mixed.nodes[2].ext, 'mp4', 'ext 取 ico');
  checkTrue(!mixed.nodes[4].isVideo, 'txt 不是视频');
  checkTrue(!mixed.nodes[5].isVideo, 'iv=0 且非视频后缀 → 不是视频');
  checkTrue(mixed.nodes[2].canPlay, '视频文件可取链');

  print('== 2. 排序：目录 → 视频 → 其他，同组按名称 ==');
  checkEq(mixed.nodes[0].name, 'Movies', '目录组按名升序 1');
  checkEq(mixed.nodes[1].name, 'Series', '目录组按名升序 2');
  checkEq(mixed.nodes[2].name, 'A.mp4', '视频组按名升序 1');
  checkEq(mixed.nodes[3].name, 'B.mkv', '视频组按名升序 2');
  checkEq(mixed.nodes[4].name, 'cover.jpg', '其他文件组按名升序 1');
  checkEq(mixed.nodes[5].name, 'readme.txt', '其他文件组按名升序 2');
  final lastDir = mixed.nodes.lastIndexWhere((n) => n.isDir);
  final firstOther = mixed.nodes.indexWhere((n) => !n.isDir && !n.isVideo);
  checkTrue(lastDir < firstOther, '目录全部排在「其他文件」之前');

  print('== 3. data 为 Map 的三种形态 ==');
  final listForm = parsePan115FileList(decode(fxMapList));
  checkTrue(listForm.ok, 'data.list 形态解析成功');
  checkEq(listForm.nodes.length, 2, 'data.list 条目数');
  checkEq(listForm.count, 2, 'data.count 透出');
  checkEq(listForm.nodes[1].name, 'Sample.mov', 'data.list 内的文件');
  checkTrue(listForm.nodes[1].isVideo, 'mov 命中视频白名单');
  final filesForm = parsePan115FileList(decode(fxMapFiles));
  checkEq(filesForm.nodes.length, 1, 'data.files 条目数');
  checkEq(filesForm.total, 42, 'data.total 透出');
  checkTrue(filesForm.nodes[0].isVideo, 'webm 无 iv 也判为视频');
  final nestedForm = parsePan115FileList(decode(fxMapNested));
  checkEq(nestedForm.nodes.length, 1, 'data.data 嵌套形态条目数');
  checkTrue(nestedForm.nodes[0].isDir, '嵌套形态里的目录');

  print('== 4. iv 缺失时按扩展名兜底 ==');
  final noIv = parsePan115FileList(decode(fxNoIv));
  final byName = <String, Pan115Node>{for (final n in noIv.nodes) n.name: n};
  checkTrue(byName['Upper.MKV']!.isVideo, '大写 .MKV 后缀判为视频');
  checkEq(byName['Upper.MKV']!.ext, 'mkv', '无 ico 时从文件名取后缀');
  checkTrue(byName['Live.ts']!.isVideo, '.ts 命中白名单');
  checkTrue(!byName['Disc.iso']!.isVideo, '.iso 不在白名单');
  checkTrue(!byName['NoExt']!.isVideo, '无后缀不臆断为视频');
  checkTrue(byName['Zero.mp4']!.isVideo, 'iv=0 但后缀命中 → 仍算视频');
  checkTrue(kPan115VideoExt.contains('m2ts'), '白名单含 m2ts');
  checkTrue(kPan115VideoExt.contains('divx'), '白名单含 divx');
  checkTrue(isPan115VideoExt('MKV'), 'isPan115VideoExt 大小写不敏感');
  checkTrue(!isPan115VideoExt('iso'), 'isPan115VideoExt 排除 iso');
  checkEq(pan115ExtOfName('a.b.mkv'), 'mkv', '取最后一个点后的后缀');
  checkEq(pan115ExtOfName('noext'), '', '无后缀返回空串');

  print('== 5. state=false 的错误口径 ==');
  final auth = parsePan115FileList(decode(fxAuth990001));
  checkTrue(!auth.ok, 'errNo=990001 → ok=false');
  checkEq(auth.message, '当前会话无该接口权限（115 按登录渠道分域鉴权）', '990001 覆盖服务端「登录超时」误导文案');
  checkEq(auth.nodes.length, 0, '被拒时不产出条目');
  final other = parsePan115FileList(decode(fxStateFalse));
  checkTrue(!other.ok, 'errNo=2001 → ok=false');
  checkEq(other.message, '操作过于频繁（errNo=2001）', '其他错误码带上 errNo');

  print('== 6. 空目录 / 畸形响应 ==');
  final empty = parsePan115FileList(decode(fxEmpty));
  checkTrue(empty.ok, '空 data 且 state=true → ok=true（是空态不是错误）');
  checkEq(empty.nodes.length, 0, '空目录无条目');
  checkEq(empty.message, '', '空目录不带错误信息');
  checkTrue(decode(fxMalformed) == null, '畸形 JSON 确实无法 decode');
  final broken = parsePan115FileList(fxMalformed);
  checkTrue(!broken.ok, '畸形 JSON 原串传入 → ok=false（不抛异常）');
  final html = parsePan115FileList(fxHtml);
  checkTrue(!html.ok, 'HTML 风控页 → ok=false');
  checkTrue(html.message.contains('无法解析'), '风控页给出可读结论');
  final nullish = parsePan115FileList(null);
  checkTrue(!nullish.ok, 'null 响应 → ok=false');

  print('');
  print('通过 $_pass 条，失败 $_fail 条');
  if (_fail > 0) {
    print('pan115_files_check 存在失败断言');
    exit(1);
  }
  print('pan115_files_check 全部通过');
}
