// 纯 Dart 复跑「第三方素材许可与资产自洽」的核心断言。
//
// 用途：许可全文是**发版硬门槛**（删了不许发版），而这件事 flutter analyze /
// flutter test 都管不到 —— 它们是代码门禁，不会因为 assets/icons/LICENSE.txt
// 被删而失败。本脚本守的就是这条缝。
//
// 运行：**cd app/gui && dart .tools/asset_license_check.dart**
//       ^ 同 app_route_check.dart：不要写成 `dart run`，否则走 dartdev 会
//         触发 sqlite3 的 native assets 构建并挂死。
//
// 【覆盖范围 —— 写清楚边界】
// 覆盖：assets/ 下三方素材（图标 / 音效 / 字体）的**许可全文是否随包**、
//       index.json ↔ hub_icons.dart 的码位一致性、pubspec 是否声明了这些文件。
// 不覆盖：许可条款的法律正确性（那是人工判断，脚本只能守「文件在不在」）。
import 'dart:convert';
import 'dart:io';

import '../lib/core/navigation/app_route.dart';

int _pass = 0;
int _fail = 0;

void checkTrue(bool cond, String label) {
  if (cond) {
    _pass++;
    print('  [ok]   $label');
  } else {
    _fail++;
    print('  [FAIL] $label');
  }
}

void checkEq(Object? actual, Object? expected, String label) {
  if ('$actual' == '$expected') {
    _pass++;
    print('  [ok]   $label -> $actual');
  } else {
    _fail++;
    print('  [FAIL] $label -> $actual，期望 $expected');
  }
}

/// 定位仓库内的文件：优先按脚本自身位置解析（`dart .tools/x.dart` 时 cwd 不定）
File sourceFile(String relativeFromGuiRoot) {
  final fromScript = File(
    Platform.script.resolve(relativeFromGuiRoot).toFilePath(),
  );
  if (fromScript.existsSync()) return fromScript;
  return File(relativeFromGuiRoot);
}

String readSource(String relativeFromGuiRoot) =>
    sourceFile(relativeFromGuiRoot).readAsStringSync();

bool exists(String relativeFromGuiRoot) =>
    sourceFile(relativeFromGuiRoot).existsSync();

/// 许可文件必须存在，且内容里能找到特征串 —— 防止「建了个空文件糊弄门禁」
void checkLicenseFile(String path, String needle, String label) {
  if (!exists(path)) {
    _fail++;
    print('  [FAIL] $label：文件缺失 $path');
    return;
  }
  final text = readSource(path);
  if (text.trim().isEmpty) {
    _fail++;
    print('  [FAIL] $label：$path 是空文件');
    return;
  }
  checkTrue(text.contains(needle), '$label（$path 含 "$needle"）');
}

void main() {
  print('— 第三方素材许可全文必须随包（发版硬门槛）—');
  checkLicenseFile(
    'assets/fonts/HarmonyOS_Sans_SC_LICENSE.txt',
    'Huawei',
    '字体许可',
  );
  checkLicenseFile(
    'assets/fonts/hm_symbol_LICENSE.txt',
    'Apache License',
    '图标字体许可（HarmonyOS Symbol 子集，OpenHarmony，Apache-2.0）',
  );
  checkLicenseFile(
    'assets/icons/LICENSE.txt',
    'Copyright (c) 2020 Microsoft Corporation',
    '图标许可（Fluent UI System Icons，MIT）',
  );
  checkLicenseFile(
    'assets/sounds/LICENSE.txt',
    'Creative Commons Zero',
    '音效许可（Kenney，CC0）',
  );
  checkLicenseFile(
    'assets/sounds/CC0-1.0-legalcode.txt',
    'CC0 1.0 Universal',
    'CC0 法律文本全文',
  );
  checkLicenseFile(
    'assets/sounds/LICENSE-NOTICE.txt',
    'Kenney',
    '音效来历说明（关于页展示的就是这份）',
  );

  print('— 图标字体：index.json ↔ hub_icons.dart ↔ SVG 三者对齐 —');
  final indexRaw = readSource('assets/icons/index.json');
  final index = jsonDecode(indexRaw) as Map<String, dynamic>;
  final meta = index['meta'] as Map<String, dynamic>;
  final icons = index['icons'] as Map<String, dynamic>;
  final count = meta['count'] as int;
  checkEq(icons.length, count, 'meta.count == icons 条数');
  checkEq(meta['license'], 'MIT', 'meta.license');
  checkEq(meta['fontFile'], 'hub_icons.ttf', 'meta.fontFile');
  checkEq(meta['upem'], 1000, 'meta.upem');
  checkTrue(
    '${meta['source']}'.contains('Fluent UI System Icons'),
    'meta.source 指向 Fluent（不是已下线的 HarmonyOS Icons）',
  );
  // 禁止 re-import 无许可源：HarmonyOS Icons 曾在 2026-10 前使用过，
  // 包内没有任何 LICENSE，属发版风险，这里钉死不许回退。
  checkTrue(
    !indexRaw.contains('HarmonyOS Icons'),
    'index.json 不得再出现 HarmonyOS Icons（该源无 LICENSE）',
  );

  final dartSrc = readSource('lib/ui/hub_icons.dart');
  final declaredInDart = RegExp(r"static const IconData (\w+) = IconData\(")
      .allMatches(dartSrc)
      .map((m) => m.group(1)!)
      .toList(growable: false);
  checkEq(declaredInDart.length, count, 'hub_icons.dart 常量数 == index 条数');
  checkEq(
    declaredInDart,
    icons.keys.toList(growable: false),
    'hub_icons.dart 顺序 == index.json 顺序（码位依赖顺序）',
  );

  var cp = 0xE000;
  var contiguous = true;
  for (final name in icons.keys) {
    final e = icons[name] as Map<String, dynamic>;
    if (e['codepoint'] != cp) contiguous = false;
    if (!exists('assets/icons/${e['file']}')) {
      _fail++;
      print('  [FAIL] $name 的 SVG 缺失：${e['file']}');
    }
    cp++;
  }
  checkTrue(contiguous, '码位从 0xE000 起连续无空洞');
  checkTrue(exists('assets/icons/hub_icons.ttf'), 'hub_icons.ttf 存在');
  checkTrue(
    sourceFile('assets/icons/hub_icons.ttf').lengthSync() > 10000,
    'hub_icons.ttf 非空（122 个字形不可能小于 10 KB）',
  );

  print('— 提示音：10 个语义音齐全且非空 —');
  const sounds = <String>[
    'click',
    'error',
    'import_done',
    'notify',
    'scan_done',
    'startup',
    'success',
    'task_done',
    'task_start',
    'warning',
  ];
  for (final s in sounds) {
    final f = sourceFile('assets/sounds/$s.wav');
    checkTrue(f.existsSync() && f.lengthSync() > 1000, '$s.wav 存在且非空');
  }

  print('— pubspec 必须显式声明这些许可文件（否则打不进产物）—');
  final pubspec = readSource('pubspec.yaml');
  for (final decl in <String>[
    '- assets/fonts/HarmonyOS_Sans_SC_LICENSE.txt',
    '- assets/fonts/hm_symbol_LICENSE.txt',
    '- assets/icons/LICENSE.txt',
    '- assets/sounds/LICENSE.txt',
    '- assets/sounds/CC0-1.0-legalcode.txt',
  ]) {
    checkTrue(pubspec.contains(decl), 'pubspec 声明 $decl');
  }
  checkTrue(pubspec.contains('- family: HubIcons'), 'pubspec 声明 HubIcons 字体族');
  checkTrue(pubspec.contains('- family: HMSymbol'), 'pubspec 声明 HMSymbol 字体族');
  checkTrue(
    pubspec.contains('- family: HarmonyOS'),
    'pubspec 声明 HarmonyOS 字体族',
  );

  print('— 4.0 新增设置项已落地（图标风格 / 提示音）—');
  final settings = readSource('lib/core/db/settings.dart');
  checkTrue(settings.contains('enum AppIconStyle'), 'AppIconStyle 枚举存在');
  for (final v in <String>['auto', 'outline', 'filled']) {
    checkTrue(
      RegExp(
        'AppIconStyle\\s*\\{[^}]*\\b$v\\b',
        dotAll: true,
      ).hasMatch(settings),
      'AppIconStyle 含 $v',
    );
  }
  checkTrue(settings.contains("this.iconStyle = 'auto'"), 'iconStyle 默认 auto');
  checkTrue(
    settings.contains("'iconStyle': iconStyle,"),
    'iconStyle 落盘 toJson',
  );
  checkTrue(
    settings.contains("iconStyle: AppIconStyle.parse(g['iconStyle']"),
    'sanitize 归一化 iconStyle（脏值不崩）',
  );

  final registry = readSource('lib/features/settings/registry.dart');
  checkTrue(registry.contains("id: 'sound'"), 'registry 登记提示音分区');
  checkTrue(registry.contains('SoundSection.new'), 'registry 引用 SoundSection');

  final providers = readSource('lib/state/providers.dart');
  checkTrue(
    providers.contains('patchIconStyle'),
    'providers 提供 patchIconStyle',
  );
  checkTrue(providers.contains('patchSound'), 'providers 提供 patchSound');

  final shell = readSource('lib/ui/app_shell.dart');
  checkTrue(
    shell.contains('AppIconStyle.auto => selected ? filled : outlined'),
    '_NavIcon 按图标风格解析（auto 跟随选中态）',
  );

  print('— 顺带守一条：路由层没被这次改动碰坏 —');
  checkEq(AppRoute.values.length, 7, 'AppRoute 枚举数量');

  print('');
  print('asset_license_check: $_pass passed, $_fail failed');
  if (_fail > 0) {
    throw StateError('asset_license_check 未通过：$_fail 条断言失败');
  }
}
