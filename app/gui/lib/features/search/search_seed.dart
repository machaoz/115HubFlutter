import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation/app_route.dart';
import '../../state/providers.dart';

/// 从「发现」等页面跳转到搜索时携带的检索意图。
///
/// 【B1 关键】V1.x 的「去搜索」直接把**资源原名**（多为英文）丢进搜索框，
/// 中文用户看到的是 0 结果或一堆英文条目。正确顺序是：
///   **先用发现页的展示名（中文）检索 → 无结果再用原名回退**。
class SearchSeed {
  const SearchSeed(this.primary, {this.fallback});

  /// 首轮检索词：发现页展示的名称（通常是中文片名）
  final String primary;

  /// 回退检索词：资源原名 / 译名（primary 无结果时才使用）
  final String? fallback;
}

/// 全局检索意图通道（导航到搜索页时投递，搜索页消费后置空）
final ValueNotifier<SearchSeed?> searchSeedNotifier =
    ValueNotifier<SearchSeed?>(null);

/// 跳转搜索页并注入检索意图
void goToSearch(BuildContext context, SearchSeed seed) {
  searchSeedNotifier.value = seed;
  ProviderScope.containerOf(context)
      .read(navIndexProvider.notifier)
      .select(AppRoute.search);
}

/// 纯函数：决定是否需要「回退检索」，以及回退词是什么。
///
/// 规则（顺序即优先级）：
///  1. 已有结果 → 不回退（返回 null）
///  2. 种子自带 fallback（发现页跳转）→ 用它
///  3. 命中中文输入解析出的原名（手工输入场景）→ 用它
///  4. 回退词与已用词相同（忽略大小写）→ 不回退，避免原地打转
///
/// 抽成纯函数是为了把 B1 的语义固化进单测，避免后续重构改回去。
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
