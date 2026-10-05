import 'package:flutter_test/flutter_test.dart';
import 'package:magnetic115hub/features/search/search_seed.dart';

/// B1 护栏：发现页「去搜索」的检索顺序必须是
/// **先展示名（中文）→ 无结果再回退原名**。
/// 若本机 flutter_tester 被拦，等价断言见 `.tools/search_fallback_check.dart`。
void main() {
  group('nextSearchFallback', () {
    test('已有结果 → 不回退', () {
      expect(
        nextSearchFallback(hasResults: true, used: '沙丘', seedFallback: 'Dune'),
        isNull,
      );
    });

    test('无结果 + 种子带原名 → 回退原名', () {
      expect(
        nextSearchFallback(hasResults: false, used: '沙丘', seedFallback: 'Dune'),
        'Dune',
      );
    });

    test('无结果 + 豆瓣解析出原名 → 回退原名', () {
      expect(
        nextSearchFallback(
          hasResults: false,
          used: '沙丘',
          resolvedOriginal: 'Dune',
        ),
        'Dune',
      );
    });

    test('种子原名优先于解析原名', () {
      expect(
        nextSearchFallback(
          hasResults: false,
          used: '沙丘',
          seedFallback: 'Dune',
          resolvedOriginal: 'Dune Part Two',
        ),
        'Dune',
      );
    });

    test('回退词两端空白被裁剪', () {
      expect(
        nextSearchFallback(
          hasResults: false,
          used: '沙丘',
          seedFallback: '  Dune  ',
        ),
        'Dune',
      );
    });

    test('回退词与已用词相同（忽略大小写）→ 不回退，防止原地打转', () {
      expect(
        nextSearchFallback(
          hasResults: false,
          used: 'Dune',
          seedFallback: 'dune',
        ),
        isNull,
      );
    });

    test('两个候选都与已用词相同 → 不回退', () {
      expect(
        nextSearchFallback(
          hasResults: false,
          used: 'Dune',
          seedFallback: 'dune',
          resolvedOriginal: 'DUNE',
        ),
        isNull,
      );
    });

    test('首个有效候选胜出', () {
      expect(
        nextSearchFallback(
          hasResults: false,
          used: '沙丘',
          seedFallback: 'dune',
          resolvedOriginal: 'Dune',
        ),
        'dune',
      );
    });

    test('没有任何回退候选 → 不回退', () {
      expect(nextSearchFallback(hasResults: false, used: '沙丘'), isNull);
    });

    test('候选为空白串 → 视为无候选', () {
      expect(
        nextSearchFallback(
          hasResults: false,
          used: '沙丘',
          seedFallback: '',
          resolvedOriginal: '   ',
        ),
        isNull,
      );
    });
  });

  group('SearchSeed 语义', () {
    test('primary 必填、fallback 可选', () {
      const a = SearchSeed('沙丘');
      const b = SearchSeed('沙丘', fallback: 'Dune');
      expect(a.primary, '沙丘');
      expect(a.fallback, isNull);
      expect(b.fallback, 'Dune');
    });
  });
}
