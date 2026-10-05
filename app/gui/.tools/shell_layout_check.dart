// 纯 Dart 复跑「壳层布局设置」的核心断言（导航/状态栏自定义）。
//
// 用途：本机 flutter_tester 被安全策略拦住时，用 Dart VM 等价验证纯函数逻辑。
// 运行：cd app/gui && dart run .tools/shell_layout_check.dart
//
// 为什么能纯 Dart 跑：`lib/core/db/shell_layout.dart` 刻意零依赖
// （不 import flutter / sqlite），因此这里直接 import 源码断言，不做逻辑复刻。
// 涉及 AppSettings 整包（落在 settings.dart，依赖 flutter/services）的断言
// 放在 test/settings_shell_layout_test.dart，由 CI 的 flutter test 覆盖。
import 'dart:convert';

import '../lib/core/db/shell_layout.dart';

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

/// 真·JSON 往返（走后端存储同一路径），避免只测内存对象
Map<String, dynamic> jsonOf(Object o) =>
    jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

void main() {
  print('— ShellLayoutSettings 默认值 —');
  const l = ShellLayoutSettings();
  checkEq(l.navPosition, NavPosition.auto, '默认导航位置');
  checkEq(l.showNavLabels, true, '默认显示导航标签');
  checkEq(l.statusBarPosition, StatusBarPosition.bottom, '默认状态栏位置');
  checkTrue(l.showStatusPage && l.showStatusDbVersion, '默认显示页面与库版本');
  checkTrue(l.showStatusFts && l.showStatusAppVersion, '默认显示 FTS 与应用版本');
  checkTrue(l.hasStatusContent, '默认 hasStatusContent');

  print('— copyWith 语义 —');
  final next = l.copyWith(navPosition: NavPosition.right, showStatusFts: false);
  checkEq(next.navPosition, NavPosition.right, 'copyWith 覆盖导航位置');
  checkEq(next.showStatusFts, false, 'copyWith 关闭 FTS');
  checkEq(next.showNavLabels, true, 'copyWith 未传字段保持');
  checkEq(next.showStatusPage, true, 'copyWith 未传字段保持（页面）');
  checkTrue(
    !l
        .copyWith(
          showStatusPage: false,
          showStatusDbVersion: false,
          showStatusFts: false,
          showStatusAppVersion: false,
        )
        .hasStatusContent,
    '四项全关 → hasStatusContent=false',
  );

  print('— 解析：缺字段 / 半段 / 脏值 —');
  checkEq(
    ShellLayoutSettings.from(null),
    const ShellLayoutSettings(),
    'null → 全默认',
  );
  checkEq(
    ShellLayoutSettings.from(<String, dynamic>{}),
    const ShellLayoutSettings(),
    '空 Map → 全默认',
  );
  for (final bad in <Object?>['oops', 42, <Object?>[]]) {
    checkEq(
      ShellLayoutSettings.from(bad),
      const ShellLayoutSettings(),
      '非 Map(${bad.runtimeType}) → 全默认',
    );
  }

  final half = ShellLayoutSettings.from(<String, dynamic>{
    'navPosition': 'bottom',
  });
  checkEq(half.navPosition, NavPosition.bottom, '半段 shell 生效项');
  checkEq(half.showNavLabels, true, '半段 shell 缺失项取默认');

  final badEnum = ShellLayoutSettings.from(<String, dynamic>{
    'navPosition': 'top-left',
    'statusBarPosition': 'middle',
  });
  checkEq(badEnum.navPosition, NavPosition.auto, '未知导航值回落 auto');
  checkEq(
    badEnum.statusBarPosition,
    StatusBarPosition.bottom,
    '未知状态栏值回落 bottom',
  );

  final dirty = ShellLayoutSettings.from(<String, dynamic>{
    'navPosition': 42,
    'statusBarPosition': <String, dynamic>{'a': 1},
  });
  checkEq(dirty.navPosition, NavPosition.auto, '数字脏值回落');
  checkEq(dirty.statusBarPosition, StatusBarPosition.bottom, 'Map 脏值回落');

  final nonBool = ShellLayoutSettings.from(<String, dynamic>{
    'showNavLabels': 'yes',
    'showStatusFts': 0,
  });
  checkEq(nonBool.showNavLabels, true, '非布尔 showNavLabels → true');
  checkEq(nonBool.showStatusFts, true, '非布尔 showStatusFts → true');

  final explicitFalse = ShellLayoutSettings.from(<String, dynamic>{
    'showNavLabels': false,
    'statusBarPosition': 'hidden',
    'showStatusDbVersion': false,
  });
  checkEq(explicitFalse.showNavLabels, false, '显式 false 保留');
  checkEq(
    explicitFalse.statusBarPosition,
    StatusBarPosition.hidden,
    'hidden 保留（不回落 bottom）',
  );
  checkEq(explicitFalse.showStatusDbVersion, false, '关闭库版本保留');

  print('— 落库口径：枚举写名字 —');
  final s = const ShellLayoutSettings().copyWith(
    navPosition: NavPosition.right,
    statusBarPosition: StatusBarPosition.hidden,
  );
  final shell = s.toJson();
  checkEq(shell['navPosition'], 'right', 'toJson 写枚举名');
  checkEq(shell['statusBarPosition'], 'hidden', 'toJson 写枚举名（状态栏）');
  checkEq(shell.length, 7, 'shell 段字段数');

  print('— 幂等：toJson → from 往返 —');
  final a = ShellLayoutSettings.from(<String, dynamic>{
    'navPosition': 'left',
    'showStatusPage': false,
  });
  final b = ShellLayoutSettings.from(jsonOf(a.toJson()));
  checkEq(b.navPosition, NavPosition.left, '幂等：导航位置');
  checkEq(b.showStatusPage, false, '幂等：关闭页面');
  checkEq(b, a, '幂等：整体相等');

  print('— 相等性（配置变更检测依赖它） —');
  checkTrue(
    const ShellLayoutSettings() !=
        const ShellLayoutSettings().copyWith(showStatusFts: false),
    '单字段变更 → 不相等',
  );
  checkEq(
    const ShellLayoutSettings().hashCode,
    const ShellLayoutSettings().hashCode,
    '同值 hashCode 一致',
  );

  print('');
  print('shell_layout_check: $_pass passed, $_fail failed');
  if (_fail > 0) {
    throw StateError('shell_layout_check 未通过：$_fail 条断言失败');
  }
}
