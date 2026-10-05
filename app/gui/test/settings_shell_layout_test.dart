import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/core/db/settings.dart';

void main() {
  group('ShellLayoutSettings 默认值', () {
    test('默认：自动导航 + 显示标签 + 底部状态栏 + 四项内容全开', () {
      const l = ShellLayoutSettings();
      expect(l.navPosition, NavPosition.auto);
      expect(l.showNavLabels, isTrue);
      expect(l.statusBarPosition, StatusBarPosition.bottom);
      expect(l.showStatusPage, isTrue);
      expect(l.showStatusDbVersion, isTrue);
      expect(l.showStatusFts, isTrue);
      expect(l.showStatusAppVersion, isTrue);
      expect(l.hasStatusContent, isTrue);
    });

    test('AppSettings 默认带壳层布局，且可整包 JSON 往返', () {
      final s = AppSettings.sanitize(null);
      expect(s.shellLayout, const ShellLayoutSettings());

      final round = AppSettings.sanitize(jsonDecode(jsonEncode(s.toJson())));
      expect(round.shellLayout.navPosition, NavPosition.auto);
      expect(round.shellLayout.statusBarPosition, StatusBarPosition.bottom);
    });

    test('copyWith 只覆盖传入字段', () {
      const l = ShellLayoutSettings();
      final next = l.copyWith(
        navPosition: NavPosition.right,
        showStatusFts: false,
      );
      expect(next.navPosition, NavPosition.right);
      expect(next.showStatusFts, isFalse);
      // 未传入的字段保持
      expect(next.showNavLabels, isTrue);
      expect(next.statusBarPosition, StatusBarPosition.bottom);
      expect(next.showStatusPage, isTrue);
      expect(next.showStatusAppVersion, isTrue);
    });

    test('四项内容全关 → hasStatusContent=false（AppShell 不再渲染空条）', () {
      final l = const ShellLayoutSettings().copyWith(
        showStatusPage: false,
        showStatusDbVersion: false,
        showStatusFts: false,
        showStatusAppVersion: false,
      );
      expect(l.hasStatusContent, isFalse);
    });
  });

  group('向后兼容：旧库 JSON 没有 shell 段', () {
    test('缺失 shell → 全取默认，其余字段不受影响', () {
      final s = AppSettings.sanitize(<String, dynamic>{
        'general': <String, dynamic>{
          'theme': 'dark',
          'themePreset': 'midnight',
          'startPage': 'library',
        },
        'data': <String, dynamic>{'retentionDays': 7},
      });
      expect(s.shellLayout, const ShellLayoutSettings());
      expect(s.presetId, ThemePresetId.midnight);
      expect(s.startPage, 'library');
      expect(s.retentionDays, 7);
    });

    test('shell 段只写了一半 → 缺失项取默认，已有项生效', () {
      final s = AppSettings.sanitize(<String, dynamic>{
        'shell': <String, dynamic>{'navPosition': 'bottom'},
      });
      expect(s.shellLayout.navPosition, NavPosition.bottom);
      expect(s.shellLayout.showNavLabels, isTrue);
      expect(s.shellLayout.statusBarPosition, StatusBarPosition.bottom);
    });

    test('shell 落在 general 下（早期草稿口径）也能读出', () {
      final s = AppSettings.sanitize(<String, dynamic>{
        'general': <String, dynamic>{
          'shell': <String, dynamic>{'statusBarPosition': 'top'},
        },
      });
      expect(s.shellLayout.statusBarPosition, StatusBarPosition.top);
    });
  });

  group('非法值钳制', () {
    test('未知枚举字符串 → 回落默认', () {
      final s = AppSettings.sanitize(<String, dynamic>{
        'shell': <String, dynamic>{
          'navPosition': 'top-left',
          'statusBarPosition': 'middle',
        },
      });
      expect(s.shellLayout.navPosition, NavPosition.auto);
      expect(s.shellLayout.statusBarPosition, StatusBarPosition.bottom);
    });

    test('非字符串脏值（数字 / Map）→ 回落默认，不抛异常', () {
      final s = AppSettings.sanitize(<String, dynamic>{
        'shell': <String, dynamic>{
          'navPosition': 42,
          'statusBarPosition': <String, dynamic>{'a': 1},
        },
      });
      expect(s.shellLayout.navPosition, NavPosition.auto);
      expect(s.shellLayout.statusBarPosition, StatusBarPosition.bottom);
    });

    test('shell 本身是脏值（字符串 / null）→ 取默认，绝不崩', () {
      expect(
        AppSettings.sanitize(<String, dynamic>{'shell': 'oops'}).shellLayout,
        const ShellLayoutSettings(),
      );
      expect(
        AppSettings.sanitize(<String, dynamic>{'shell': null}).shellLayout,
        const ShellLayoutSettings(),
      );
      expect(
        AppSettings.sanitize(<String, dynamic>{'shell': 7}).shellLayout,
        const ShellLayoutSettings(),
      );
    });

    test('布尔项传入非布尔 → 取默认 true', () {
      final s = AppSettings.sanitize(<String, dynamic>{
        'shell': <String, dynamic>{'showNavLabels': 'yes', 'showStatusFts': 0},
      });
      expect(s.shellLayout.showNavLabels, isTrue);
      expect(s.shellLayout.showStatusFts, isTrue);
    });

    test('显式 false 会被保留（不是被默认覆盖）', () {
      final s = AppSettings.sanitize(<String, dynamic>{
        'shell': <String, dynamic>{
          'showNavLabels': false,
          'statusBarPosition': 'hidden',
          'showStatusDbVersion': false,
        },
      });
      expect(s.shellLayout.showNavLabels, isFalse);
      expect(s.shellLayout.statusBarPosition, StatusBarPosition.hidden);
      expect(s.shellLayout.showStatusDbVersion, isFalse);
    });
  });

  group('写入落库口径', () {
    test('toJson 写入 shell 段，且是枚举名字符串', () {
      final s = AppSettings.sanitize(null).copyWith(
        shellLayout: const ShellLayoutSettings().copyWith(
          navPosition: NavPosition.right,
          statusBarPosition: StatusBarPosition.hidden,
        ),
      );
      final j = s.toJson();
      final shell = j['shell'] as Map<String, dynamic>;
      expect(shell['navPosition'], 'right');
      expect(shell['statusBarPosition'], 'hidden');
      expect(shell.keys, hasLength(7));
    });

    test('sanitize 之后再 toJson 再 sanitize 稳定（幂等）', () {
      final a = AppSettings.sanitize(<String, dynamic>{
        'shell': <String, dynamic>{
          'navPosition': 'left',
          'showStatusPage': false,
        },
      });
      final b = AppSettings.sanitize(jsonDecode(jsonEncode(a.toJson())));
      expect(b.shellLayout.navPosition, NavPosition.left);
      expect(b.shellLayout.showStatusPage, isFalse);
      expect(b.shellLayout.showStatusFts, isTrue);
    });
  });
}
