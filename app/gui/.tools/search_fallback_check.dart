// 纯 Dart 复跑 test/search_fallback_test.dart 的全部断言（B1 语义护栏）。
// 用途：本机 flutter_tester 被安全策略拦住时，用 Dart VM 等价验证纯函数逻辑。
// 运行：cd app/gui && dart run .tools/search_fallback_check.dart
//
// 注意：search_seed.dart 依赖 Flutter（ProviderScope），因此这里只 import 到不了。
// 为保证纯 Dart 可跑，本脚本用与 lib 中完全相同的实现口径在此复刻断言集；
// 真正的实现一致性由 test/search_fallback_test.dart（import lib 源码）保证。
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

/// 与 lib/features/search/search_seed.dart 的 nextSearchFallback 保持逐行一致
String? nextSearchFallback({
  required bool hasResults,
  required String used,
  String? seedFallback,
  String? resolvedOriginal,
}) {
  if (hasResults) return null;
  final usedKey = used.trim().toLowerCase();
  for (final c in <String?>[seedFallback, resolvedOriginal]) {
    final v = c?.trim() ?? '';
    if (v.isEmpty) continue;
    if (v.toLowerCase() == usedKey) continue;
    return v;
  }
  return null;
}

void main() {
  print('== B1：展示名优先、原名回退 ==');

  checkEq(
    nextSearchFallback(hasResults: true, used: '沙丘', seedFallback: 'Dune'),
    null,
    '已有结果 → 不回退',
  );
  checkEq(
    nextSearchFallback(hasResults: false, used: '沙丘', seedFallback: 'Dune'),
    'Dune',
    '无结果 + 种子带原名 → 回退原名',
  );
  checkEq(
    nextSearchFallback(hasResults: false, used: '沙丘', resolvedOriginal: 'Dune'),
    'Dune',
    '无结果 + 豆瓣解析出原名 → 回退原名',
  );
  checkEq(
    nextSearchFallback(
      hasResults: false,
      used: '沙丘',
      seedFallback: 'Dune',
      resolvedOriginal: 'Dune Part Two',
    ),
    'Dune',
    '种子原名优先于解析原名',
  );
  checkEq(
    nextSearchFallback(hasResults: false, used: '沙丘', seedFallback: '  Dune  '),
    'Dune',
    '回退词两端空白被裁剪',
  );
  checkEq(
    nextSearchFallback(hasResults: false, used: 'Dune', seedFallback: 'dune'),
    null,
    '回退词与已用词相同（忽略大小写）→ 不回退，防止原地打转',
  );
  checkEq(
    nextSearchFallback(
      hasResults: false,
      used: 'Dune',
      seedFallback: 'dune',
      resolvedOriginal: 'DUNE',
    ),
    null,
    '两个候选都与已用词相同 → 不回退',
  );
  checkEq(
    nextSearchFallback(
      hasResults: false,
      used: '沙丘',
      seedFallback: 'dune',
      resolvedOriginal: 'Dune',
    ),
    'dune',
    '首个有效候选胜出，不做去重后重排',
  );
  checkEq(
    nextSearchFallback(hasResults: false, used: '沙丘'),
    null,
    '没有任何回退候选 → 不回退',
  );
  checkEq(
    nextSearchFallback(
      hasResults: false,
      used: '沙丘',
      seedFallback: '',
      resolvedOriginal: '   ',
    ),
    null,
    '候选为空白串 → 视为无候选',
  );

  print('');
  print('通过 $_pass 条，失败 $_fail 条');
  if (_fail > 0) throw StateError('search_fallback_check 存在失败断言');
}
