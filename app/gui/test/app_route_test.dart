import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/core/db/settings.dart';
import 'package:magnetic115hub/navigation/app_routes.dart';

void main() {
  group('AppRoute 解析', () {
    test('route id 与枚举名一致，且 kAppPages 顺序 = 枚举顺序', () {
      expect(
        kAppPages.map((p) => p.id).toList(),
        AppRoute.values.map((r) => r.id).toList(),
      );
    });

    test('全量注册序 ↔ 路由互转（= 枚举序，与可见性无关）', () {
      for (var i = 0; i < kAppPages.length; i++) {
        expect(registeredIndex(registeredRouteAt(i)), i);
      }
    });

    test('可见序 ↔ 路由互转', () {
      for (var i = 0; i < kVisiblePages.length; i++) {
        expect(
          visibleIndex(visibleRouteAt(i, kVisiblePages), kVisiblePages),
          i,
        );
      }
    });

    test('脏值 / 越界 → 回落默认，不抛异常', () {
      expect(AppRouteX.tryParse(null), isNull);
      expect(AppRouteX.tryParse(''), isNull);
      expect(AppRouteX.tryParse('nope'), isNull);
      expect(AppRouteX.tryParse(99), isNull);
      expect(AppRouteX.tryParse(-1), isNull);
      expect(
        AppRouteX.parse(<Object>['x'], AppRoute.library),
        AppRoute.library,
      );
    });
  });

  group('可见性机制（visible=false 的路由不进导航与启动页候选）', () {
    // 【为什么改成通用不变量，而不是写死 media】
    // media 曾是唯一的隐藏项，当初把断言全写死成「media 不可见」。等它上线可见，
    // 这批断言集体失效 —— 写死具体路由名，机制一变就全红，反过来还会诱导人
    // 「为了让测试变绿把功能藏回去」（这正是 4.0 媒体页被误藏的原因）。
    // 改成对 `visible` 取反遍历：当前没有隐藏项时是空集（vacuous 通过），
    // 将来新增隐藏项会自动生效，不需要改测试。

    test('media 已注册且可见（4.0 播放功能必须能进）', () {
      expect(kAppPages.any((p) => p.route == AppRoute.media), isTrue);
      expect(AppRoute.media.visible, isTrue);
      expect(AppRouteX.visibleValues.contains(AppRoute.media), isTrue);
      expect(kVisiblePages.any((p) => p.route == AppRoute.media), isTrue);
    });

    test('visibleValues 恰好 = 全部可见路由', () {
      expect(
        AppRouteX.visibleValues,
        AppRoute.values.where((r) => r.visible).toList(),
      );
      expect(AppRouteX.visibleValues, contains(AppRoute.media));
      expect(AppRouteX.visibleValues, isNotEmpty);
    });

    test('隐藏项（若有）不出现在启动页下拉候选中', () {
      final candidates = StartPage.startPageRoutes.map((r) => r.id).toList();
      for (final r in AppRoute.values.where((r) => !r.visible)) {
        expect(candidates, isNot(contains(r.id)));
      }
      // 正向：可见项必须都能选 —— 否则功能栏里有这页，却不能设为启动页
      for (final r in AppRouteX.visibleValues) {
        expect(candidates, contains(r.id));
      }
    });

    test('隐藏项被当作当前页时，可见序回落到默认页而非越界', () {
      for (final r in AppRoute.values.where((r) => !r.visible)) {
        expect(
          visibleIndex(r, kVisiblePages),
          visibleIndex(AppRouteX.defaultStart, kVisiblePages),
        );
      }
      // 保底：默认页自身的可见序必须是有效下标（机制全绿也不能越界）
      final idx = visibleIndex(AppRouteX.defaultStart, kVisiblePages);
      expect(idx, greaterThanOrEqualTo(0));
      expect(idx, lessThan(kVisiblePages.length));
    });
  });

  group('启动页候选只认可见路由', () {
    test('库里存可见路由 → 原样生效（含 media）', () {
      expect(StartPage.startPageRoute('media'), AppRoute.media);
      expect(StartPage.startPageRoute(AppRoute.media), AppRoute.media);
      expect(StartPage.startPageRoute('library'), AppRoute.library);
    });

    test('int 下标 6 = media 能正确还原', () {
      expect(StartPage.startPageRoute(6), AppRoute.media);
      expect(StartPage.startPageRoute('6'), AppRoute.media);
    });

    test('normalizeStartPage 保留可见路由，不误回落', () {
      expect(StartPage.normalizeStartPage('media'), 'media');
      expect(StartPage.normalizeStartPage(6), 'media');
    });

    test('copyWith 保留可见路由（写入路径不丢）', () {
      final s = AppSettings.sanitize(null).copyWith(startPage: 'media');
      expect(s.startPage, 'media');
    });

    test('隐藏项（若有）经 normalize / copyWith 一律收敛到默认页', () {
      for (final r in AppRoute.values.where((r) => !r.visible)) {
        expect(StartPage.normalizeStartPage(r.id), AppRouteX.defaultStart.id);
        expect(
          AppSettings.sanitize(null).copyWith(startPage: r.id).startPage,
          AppRouteX.defaultStart.id,
        );
      }
    });
  });

  group('启动页老数据兼容（曾存 int 下标）', () {
    test('int 下标按老顺序还原：0 概览 / 1 发现 / 5 设置 / 6 媒体库', () {
      expect(StartPage.startPageRoute(0), AppRoute.overview);
      expect(StartPage.startPageRoute(1), AppRoute.discover);
      expect(StartPage.startPageRoute(2), AppRoute.search);
      expect(StartPage.startPageRoute(3), AppRoute.import);
      expect(StartPage.startPageRoute(4), AppRoute.library);
      expect(StartPage.startPageRoute(5), AppRoute.settings);
      expect(StartPage.startPageRoute(6), AppRoute.media);
    });

    test('数字字符串同样能还原', () {
      expect(StartPage.normalizeStartPage('2'), 'search');
      expect(StartPage.normalizeStartPage('5'), 'settings');
    });

    test('越界 / 未知 → 回落默认 discover，绝不抛异常', () {
      expect(StartPage.normalizeStartPage(99), 'discover');
      expect(StartPage.normalizeStartPage('99'), 'discover');
      expect(StartPage.normalizeStartPage('oops'), 'discover');
      expect(StartPage.normalizeStartPage(<String, dynamic>{}), 'discover');
      expect(StartPage.normalizeStartPage(null), 'discover');
    });

    test('老 int 值经 sanitize 后写回 id，再读仍稳定（幂等）', () {
      final old = AppSettings.sanitize(<String, dynamic>{
        'general': <String, dynamic>{'startPage': 4},
      });
      expect(old.startPage, 'library');

      final again = AppSettings.sanitize(jsonDecode(jsonEncode(old.toJson())));
      expect(again.startPage, 'library');
      // 整包设置没有被连带重置
      expect(again.shellLayout, const ShellLayoutSettings());
      expect(again.retentionDays, 30);
    });
  });

  group('层级守卫', () {
    test('core/navigation/app_route.dart 必须是零依赖纯 Dart', () {
      var dir = Directory.current;
      while (dir.parent.path != dir.path &&
          !File('${dir.path}${Platform.pathSeparator}pubspec.yaml')
              .existsSync()) {
        dir = dir.parent;
      }
      final src = File(
        [
          dir.path,
          'lib',
          'core',
          'navigation',
          'app_route.dart',
        ].join(Platform.pathSeparator),
      );
      expect(
        src.existsSync(),
        isTrue,
        reason: '找不到 app_route.dart（cwd=${Directory.current.path}）',
      );

      final text = src.readAsStringSync();
      for (final bad in <String>['package:flutter', 'package:', 'dart:ui']) {
        expect(
          text.contains("import '$bad"),
          isFalse,
          reason: 'core 层不得 import $bad（会被 .tools 的纯 Dart 脚本打破）',
        );
      }
      // 顺带守住：可见性必须还在枚举层，不能退回 UI 层
      expect(text.contains('bool get visible'), isTrue);
    });
  });
}
