// 纯 Dart 复跑「页面路由」的核心断言。
//
// 用途：本机 flutter analyze / flutter test 跑不起来时（CreateFile failed 231），
// 用 Dart VM 直接验证路由层的核心逻辑，免得「本机能否验证」只能依赖 CI。
//
// 运行：**cd app/gui && dart .tools/app_route_check.dart**
//       ^ 不要写成 `dart run .tools/app_route_check.dart`：那样会走 dartdev，
//         触发 sqlite3 的 native assets 构建并挂死。直接跑文件可绕开。
//
// 为什么能纯 Dart 跑：`lib/core/navigation/app_route.dart` 刻意零依赖
// （不 import flutter / sqlite），因此这里直接 import 源码断言，不做逻辑复刻。
//
// 【覆盖范围 —— 写清楚边界，免得后人误以为全覆盖了】
// 覆盖：core/navigation/app_route.dart（枚举 / 解析 / 可见性 / order 互转）
//       + lib/navigation/app_routes.dart 的 kAppPages **顺序**（改为读源码文本，
//         因为那个文件 import 了 flutter，纯 Dart 跑不了）
// 不覆盖：StartPage（住在 core/db/settings.dart，经 hub_database 依赖
//         flutter+sqlite3，纯 Dart 一碰就失去意义）—— 它的断言在
//         test/app_route_test.dart，由 CI 的 `flutter test` 覆盖。
import 'dart:io';

import '../lib/core/navigation/app_route.dart';

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

/// 定位仓库内的源码文件：优先按脚本自身位置解析（`dart .tools/x.dart` 时的 cwd
/// 不一定确定），找不到再退一步按当前工作目录找。
File sourceFile(String relativeFromGuiRoot) {
  final fromScript = File(
    Platform.script.resolve(relativeFromGuiRoot).toFilePath(),
  );
  if (fromScript.existsSync()) return fromScript;
  return File(relativeFromGuiRoot);
}

String readSource(String relativeFromGuiRoot) =>
    sourceFile(relativeFromGuiRoot).readAsStringSync();

/// 从 app_routes.dart 的源码里抽出 `route: AppRoute.x` 的**声明顺序**
List<String> declaredRoutes() =>
    RegExp(r'route:\s*AppRoute\.(\w+)')
        .allMatches(readSource('../lib/navigation/app_routes.dart'))
        .map((m) => m.group(1)!)
        .toList(growable: false);

void main() {
  print('— AppRoute 基础：id / label / 可见性 —');
  final names = AppRoute.values.map((r) => r.name).toList(growable: false);
  final ids = AppRoute.values.map((r) => r.id).toList(growable: false);
  checkEq(ids, names, '持久化 id == 枚举名（写库只存它，不存下标）');
  for (final r in AppRoute.values) {
    checkTrue(r.label.isNotEmpty, '${r.name} 有中文标签');
  }
  checkEq(AppRouteX.defaultStart, AppRoute.discover, '默认启动页');
  checkTrue(AppRouteX.defaultStart.visible, '默认启动页必须可见（兜底前提，见下）');

  print('— 层级守卫：core/navigation/app_route.dart 必须零依赖 —');
  // 这条守的是「.tools 能用纯 Dart 复跑」这件事的前提：
  // 一旦有人给它 import 了 flutter / 任何 package，本脚本会直接编译失败 ——
  // 但 CI failure 只会说「编译不过」，所以这里再显式断言一次，把原因写明白。
  final coreSrc = readSource('../lib/core/navigation/app_route.dart');
  for (final bad in <String>['package:flutter', 'package:', 'dart:ui']) {
    checkTrue(!coreSrc.contains("import '$bad"), 'core 层不得 import $bad');
  }
  checkTrue(coreSrc.contains('bool get visible'), '可见性仍住在枚举层（未退回 UI 层）');

  print('— kAppPages 顺序 == 枚举声明顺序（读源码文本，防顺序错位的静默 bug）—');
  final declared = declaredRoutes();
  print('  源码声明顺序：$declared');
  print('  枚举声明顺序：$names');
  checkEq(declared, names, '两处顺序完全一致');
  checkEq(declared.length, names.length, '两处长度一致');

  print('— 脏值 / 越界 → 回落默认，绝不抛异常 —');
  // 这里的 `raw is XXX` 顺序 + int.tryParse 兜底是历史数据兼容的全部实现，
  // 任何一环写错都会让老用户（库存 int 下标）落到错误页面或整包设置被重置。
  checkEq(AppRouteX.tryParse(null), null, 'null → null');
  checkEq(AppRouteX.tryParse(''), null, "'' → null");
  checkEq(AppRouteX.tryParse('   '), null, '纯空白 → null');
  checkEq(AppRouteX.tryParse(99), null, '越界 int 99 → null');
  checkEq(AppRouteX.tryParse(-1), null, '负 int -1 → null');
  checkEq(AppRouteX.tryParse('nope'), null, '未知字符串 → null');
  checkEq(AppRouteX.tryParse(2.7), null, 'double 2.7 → null（不取整、不抛）');
  checkEq(AppRouteX.tryParse(true), null, 'bool → null');
  checkEq(AppRouteX.tryParse(<String, dynamic>{}), null, '空 Map → null');
  checkEq(
    AppRouteX.parse(<Object>['x'], AppRoute.library),
    AppRoute.library,
    '无法识别 → 回落指定 fallback',
  );

  print('— 老数据：int 与数字字符串按下标还原（0 概览 … 5 设置）—');
  for (var i = 0; i < AppRoute.values.length; i++) {
    checkEq(AppRouteX.tryParse(i), AppRoute.values[i], 'int $i');
    checkEq(AppRouteX.tryParse('$i'), AppRoute.values[i], '字符串 "$i"');
  }

  print('— 全量注册序互转（持久化 / 老数据还原用，与可见性无关）—');
  for (var i = 0; i < AppRoute.values.length; i++) {
    checkEq(appRouteAt(i), AppRoute.values[i], 'appRouteAt($i)');
    checkEq(appRouteAt(i).order, i, 'appRouteAt($i).order');
  }
  checkEq(appRouteAt(-1), AppRouteX.defaultStart, 'appRouteAt(负) → 默认页');
  checkEq(appRouteAt(99), AppRouteX.defaultStart, 'appRouteAt(越界) → 默认页');

  print('— 可见路由（导航渲染 / 启动页候选的唯一来源）—');
  for (final r in AppRouteX.visibleValues) {
    checkTrue(r.visible, '${r.name} 在 visibleValues 里且可见');
  }
  final invisible = AppRoute.values.where((r) => !r.visible).toList();
  for (final r in invisible) {
    checkTrue(
      !AppRouteX.visibleValues.contains(r),
      '${r.name} 不可见 → 不在 visibleValues',
    );
    checkTrue(declared.contains(r.name), '${r.name} 仍登记在 kAppPages（占位）');
  }
  checkTrue(
    AppRouteX.visibleValues.isNotEmpty,
    'visibleValues 非空（全隐藏会让导航无页可去）',
  );

  print('');
  print('app_route_check: $_pass passed, $_fail failed');
  if (_fail > 0) {
    throw StateError('app_route_check 未通过：$_fail 条断言失败');
  }
}
