// 主题令牌（AppTokens）契约护栏
//
// 背景（docs/设计-P0-2-设置页注册化.md §5）：
// 1. `AppTokensScope.updateShouldNotify` 只看 `AppTokens.==`，但历史上 `==`
//    只比了 7 个字段（16 个里的 7 个）。今天之所以没炸，只是因为 6 套预设恰好
//    在 bg0/accent 上不同；一旦加「只改字体 / 只改图标集 / 只改密度」这类
//    不影响 bg0/accent 的设置项，UI 就不会重建 —— 属于「改了设置没反应」的
//    静默 bug，且很难靠肉眼发现。
// 2. 因此定了收录标准：**影响渲染的字段一律进 `==`**；不进的必须在字段上
//    写明原因（见 theme.dart 里的 `==` 注释）。
//
// 这个文件把上面两条固化成断言：
// - 源码文本扫描：新增字段忘补 `==` 立刻红（Dart 无反射，只能扫源码）；
// - 行为断言：改 fontFamily 必须真的触发子树重建。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:magnetic115hub/core/db/settings.dart';
import 'package:magnetic115hub/ui/theme.dart';

/// 字段想在 `==` 里豁免时，必须在字段声明上方的注释里写这个标记。
/// 扫到标记却仍出现在 `==` 里（或反过来）都会红 —— 防止标记变成橡皮图章。
const String kNoEqMarker = '不进 ==';

String _readThemeSource() {
  var dir = Directory.current;
  while (dir.parent.path != dir.path &&
      !File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
    dir = dir.parent;
  }
  final src = File(
    [dir.path, 'lib', 'ui', 'theme.dart'].join(Platform.pathSeparator),
  );
  expect(
    src.existsSync(),
    isTrue,
    reason: '找不到 lib/ui/theme.dart（cwd=${Directory.current.path}）',
  );
  return src.readAsStringSync();
}

/// 取 `class AppTokens { ... }` 的类体（到第一个顶格 `}` 为止）
String _classBody(String text) {
  final start = text.indexOf('class AppTokens {');
  expect(start, greaterThanOrEqualTo(0), reason: 'theme.dart 里找不到 AppTokens');
  final open = text.indexOf('{', start);
  final end = text.indexOf('\n}', open);
  expect(end, greaterThan(open), reason: 'AppTokens 类体没有正常收尾');
  return text.substring(open + 1, end);
}

/// 取 `operator ==` 的表达式文本（到下一个 `@override` 为止）
String _eqBody(String text) {
  final start = text.indexOf('bool operator ==(');
  expect(start, greaterThanOrEqualTo(0), reason: 'AppTokens 没有重写 ==');
  final end = text.indexOf('@override', start);
  expect(end, greaterThan(start), reason: 'operator == 后面找不到 @override');
  return text.substring(start, end);
}

void main() {
  group('AppTokens.== 收录完整性（源码扫描）', () {
    test('每个字段要么进 ==，要么在字段注释里写明豁免原因', () {
      final text = _readThemeSource();
      final body = _classBody(text);
      final eq = _eqBody(text);

      // 类体里的 `final <Type> <name>;` 就是全部字段
      final decl = RegExp(r'^  final\s+[\w<>?,\s]+\s+(\w+);', multiLine: true);
      final fields = <String>[
        for (final m in decl.allMatches(body)) m.group(1)!,
      ];
      expect(fields, isNotEmpty, reason: '没扫到任何字段，正则失效了');

      // 关键字段必须真在扫出来的列表里（正则误判的兜底）
      for (final must in <String>[
        'bg0',
        'surface1',
        'surface2',
        'surface3',
        'borderSubtle',
        'borderDisabled',
        'fontFamily',
      ]) {
        expect(fields, contains(must), reason: '$must 没被扫成字段');
      }

      for (final name in fields) {
        // 该字段声明前 400 字符（即紧邻的文档注释）里有没有豁免标记
        final idx = body.indexOf(
          RegExp(r'final\s+[\w<>?,\s]+\s+' + name + r';'),
        );
        expect(idx, greaterThanOrEqualTo(0), reason: '$name 定位失败');
        final head = body.substring(0, idx);
        final near = head.substring(head.length > 400 ? head.length - 400 : 0);
        final exempt = near.contains(kNoEqMarker);
        final inEq = RegExp(r'\b' + name + r'\b').hasMatch(eq);

        if (exempt) {
          expect(
            inEq,
            isFalse,
            reason: '$name 注释标了「$kNoEqMarker」却又出现在 == 里，标记与实现矛盾',
          );
        } else {
          expect(
            inEq,
            isTrue,
            reason:
                '$name 不在 operator == 里 —— 改了它 UI 不会重建。'
                '若它确实不影响渲染，请在字段注释里写明「$kNoEqMarker」及原因。',
          );
        }
      }
    });

    test('hashCode 与 == 收录的字段一致', () {
      final text = _readThemeSource();
      final body = _classBody(text);
      final eq = _eqBody(text);
      final hashStart = text.indexOf('int get hashCode');
      expect(hashStart, greaterThanOrEqualTo(0));
      final hashEnd = text.indexOf('\n}', hashStart);
      final hash = text.substring(hashStart, hashEnd);

      for (final m in RegExp(
        r'^  final\s+[\w<>?,\s]+\s+(\w+);',
        multiLine: true,
      ).allMatches(body)) {
        final name = m.group(1)!;
        if (RegExp(r'\b' + name + r'\b').hasMatch(eq)) {
          expect(
            RegExp(r'\b' + name + r'\b').hasMatch(hash),
            isTrue,
            reason: '$name 进了 == 却没进 hashCode（违反 hashCode/== 契约）',
          );
        }
      }
    });
  });

  group('新增令牌', () {
    test('6 套预设都补齐 surface1/2/3 与 borderSubtle/borderDisabled', () {
      for (final p in kThemePresets) {
        final t = p.tokens;
        // 层级底色必须是不透明实色（规范 §3.9：半透明叠加层不可控）
        for (final c in <Color>[t.surface1, t.surface2, t.surface3]) {
          expect(c.a, 1.0, reason: '${p.id}: 层级底色必须不透明');
        }
        // 三档必须真的分层，否则等于没加
        expect(
          <Color>{t.surface1, t.surface2, t.surface3}.length,
          3,
          reason: '${p.id}: surface1/2/3 出现重复值',
        );
        // 弱描边必须比常规描边更弱
        expect(
          t.borderSubtle.a,
          lessThan(t.border.a),
          reason: '${p.id}: borderSubtle 应弱于 border',
        );
        expect(
          t.borderDisabled.a,
          lessThanOrEqualTo(t.borderSubtle.a),
          reason: '${p.id}: borderDisabled 不应强于 borderSubtle',
        );
      }
    });

    test('textDisabled / borderFocus 是派生的，不是新增字段', () {
      final t = kTokensGraphite;
      expect(t.textDisabled, t.textDim.withValues(alpha: 0.38));
      // 换一套预设也要自动跟着变（说明真派生，不是抄死值）
      expect(
        kTokensPaper.textDisabled,
        kTokensPaper.textDim.withValues(alpha: 0.38),
      );
      expect(kTokensPaper.textDisabled, isNot(t.textDisabled));
      expect(t.borderFocus, t.accent);
      expect(kTokensOcean.borderFocus, kTokensOcean.accent);
    });

    test('surfaceSolid / surface 两个旧名都已彻底消失（硬改名，不留别名）', () {
      final text = _readThemeSource();
      expect(text.contains('surfaceSolid'), isFalse);

      // `surface` 不能只按子串查 —— buildTheme 里还有 `surface: t.surface1`
      // 这样的 ColorScheme 入参。要查的是「是否还存在名为 surface 的字段」。
      final fields = <String>[
        for (final m in RegExp(
          r'^  final\s+[\w<>?,\s]+\s+(\w+);',
          multiLine: true,
        ).allMatches(_classBody(text)))
          m.group(1)!,
      ];
      expect(
        fields,
        isNot(contains('surface')),
        reason: '旧的半透明 surface 字段复活了（规范 §3.9 已弃用，请用 surface1/2/3）',
      );
      expect(fields, contains('surface1'));
    });
  });

  group('fontFamily 单一真源', () {
    test('resolveTokens 把 fontFamily 落进令牌', () {
      final t = resolveTokens(
        preset: ThemePresetId.graphite,
        platformBrightness: Brightness.dark,
        fontFamily: AppFontFamily.system,
      );
      expect(t.fontFamily, AppFontFamily.system);
      expect(t, isNot(kTokensGraphite));
      expect(t.bg0, kTokensGraphite.bg0, reason: '改字体不应动配色');
      expect(t, kTokensGraphite.copyWith(fontFamily: AppFontFamily.system));
    });

    test('默认（harmonyOS）走同一条路径，不产生多余 copy', () {
      final t = resolveTokens(
        preset: ThemePresetId.graphite,
        platformBrightness: Brightness.dark,
      );
      expect(t.fontFamily, AppFontFamily.harmonyOS);
      expect(t, kTokensGraphite);
    });

    test('AppTokensScope 只是透传，不存第二份', () {
      final scope = AppTokensScope(
        tokens: kTokensGraphite.copyWith(fontFamily: AppFontFamily.system),
        child: const SizedBox.shrink(),
      );
      expect(scope.fontFamily, AppFontFamily.system);
    });
  });

  group('行为：改令牌必须触发重建', () {
    testWidgets('token 相等 → 不重建；只改 fontFamily → 重建', (tester) async {
      var builds = 0;
      await tester.pumpWidget(_TokenHarness(onBuild: () => builds++));
      expect(builds, 1);

      final state = tester.state<_TokenHarnessState>(
        find.byType(_TokenHarness),
      );

      // 负向对照：令牌一个字段都没变，子树不该重建
      state.swapTo(state.tokens);
      await tester.pump();
      expect(
        builds,
        1,
        reason: '令牌没变却重建了 —— updateShouldNotify 恒为 true 会造成无意义重绘',
      );

      // 只改字体：配色一个字节都没动，也必须重建
      state.swapTo(state.tokens.copyWith(fontFamily: AppFontFamily.system));
      await tester.pump();
      expect(
        builds,
        2,
        reason:
            '只改 fontFamily 没有触发重建 —— 这就是「设置里切了字体、UI 没反应」的老毛病。'
            '八成是 AppTokens.== 漏收录 fontFamily。',
      );

      // 换回来同样要重建（双向）
      state.swapTo(state.tokens.copyWith(fontFamily: AppFontFamily.harmonyOS));
      await tester.pump();
      expect(builds, 3);
    });

    test('updateShouldNotify 与 == 同源（不另开判断）', () {
      final base = kTokensGraphite;
      final a = AppTokensScope(tokens: base, child: const SizedBox.shrink());
      final same = AppTokensScope(
        tokens: base.copyWith(fontFamily: base.fontFamily),
        child: const SizedBox.shrink(),
      );
      final diff = AppTokensScope(
        tokens: base.copyWith(fontFamily: AppFontFamily.system),
        child: const SizedBox.shrink(),
      );
      expect(a.updateShouldNotify(same), isFalse, reason: '等价令牌不该通知');
      expect(a.updateShouldNotify(diff), isTrue, reason: '只改字体也该通知');
    });
  });
}

/// 宿主：只在最外层 setState 换令牌，子树靠 InheritedWidget 通知重建。
///
/// 刻意不用「重复 pumpWidget」来换令牌 —— 那样会重建整棵树，
/// 测不出 `updateShouldNotify` 到底有没有起作用。
class _TokenHarness extends StatefulWidget {
  const _TokenHarness({required this.onBuild});

  final VoidCallback onBuild;

  @override
  State<_TokenHarness> createState() => _TokenHarnessState();
}

class _TokenHarnessState extends State<_TokenHarness> {
  late AppTokens tokens = resolveTokens(
    preset: ThemePresetId.graphite,
    platformBrightness: Brightness.dark,
    fontFamily: AppFontFamily.harmonyOS,
  );

  /// 子树实例**必须缓存成同一个**。
  ///
  /// 踩过的坑：原先这里写成 `child: _BuildCounter(widget.onBuild)`，每次 build
  /// 都新建一个实例。Flutter 只要发现 widget 实例变了就会重建子树，于是无论
  /// `updateShouldNotify` 返回 true 还是 false，`builds` 都会 ++ —— 这条断言
  /// 变成恒失败的假阳性，根本测不到 InheritedWidget 的通知逻辑。
  ///
  /// 缓存后：令牌没变 → updateChild 因实例相同直接跳过，且 updateShouldNotify
  /// 为 false 不通知依赖者 → 子树不重建；令牌变了 → 依赖者被通知 → 才重建。
  late final Widget counter = _BuildCounter(widget.onBuild);

  void swapTo(AppTokens next) => setState(() => tokens = next);

  @override
  Widget build(BuildContext context) =>
      AppTokensScope(tokens: tokens, child: counter);
}

class _BuildCounter extends StatelessWidget {
  const _BuildCounter(this.onBuild);

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    // 必须真的读一次 InheritedWidget，才会登记为依赖者；
    // 不读的话 AppTokensScope 更新时根本不会通知到它，测试就成了假阳性。
    AppTokensScope.of(context);
    onBuild();
    return const SizedBox.shrink();
  }
}
