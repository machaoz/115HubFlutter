/// 发现页「人物分类」的**纯逻辑层**：目录 + JSON 解析 + 角色过滤 + 排序去重。
///
/// 刻意 **不 import flutter / dio**，全部是可测纯函数，便于：
/// - `flutter test` 直接断言（见 `test/person_catalog_test.dart`）
/// - `.tools/person_catalog_check.dart` 纯 Dart 脚本兜底校验
///
/// 网络请求本身不在这里（见 `person_board.dart` 的 `DoubanPersonService`）。
library;

/// 人物角色维度（发现页「角色」筛选）
enum PersonRole {
  director,
  actor;

  String get label => switch (this) {
    PersonRole.director => '导演',
    PersonRole.actor => '演员',
  };

  /// 代表作区块标题
  String get worksTitle => switch (this) {
    PersonRole.director => '导演代表作',
    PersonRole.actor => '参演代表作',
  };

  /// 豆瓣 `works` 接口里 `roles[]` 的匹配关键字。
  /// 实测 roles 形如 `导演` / `演员 - 自己` / `演员 - 配音`，故按「包含」匹配。
  bool matches(String roleText) => roleText.contains(label);
}

/// 地区 / 语种分类（发现页「类别」筛选）
const List<String> kPersonCategories = <String>['全部', '华语', '欧美', '日韩'];

/// 目录条目：**只存名字，不存 id**。
/// id 一律运行时经 suggest 动态解析，避免硬编码失效 id。
class PersonEntry {
  const PersonEntry({
    required this.name,
    required this.category,
    required this.roles,
  });

  final String name;

  /// 见 [kPersonCategories]（不含「全部」）
  final String category;

  /// 该人物可出现在哪些角色维度下（姜文/周星驰/北野武等导演兼演员会同时命中）
  final Set<PersonRole> roles;
}

/// 人物目录：类别 → 名字。兼顾华语 / 欧美 / 日韩，每个「类别 × 角色」≥ 6 人。
const List<PersonEntry> kPersonCatalog = <PersonEntry>[
  // ---------------------------------------------------------------- 华语
  PersonEntry(
    name: '张艺谋',
    category: '华语',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '陈凯歌',
    category: '华语',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '王家卫',
    category: '华语',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '李安',
    category: '华语',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '贾樟柯',
    category: '华语',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '姜文',
    category: '华语',
    roles: <PersonRole>{PersonRole.director, PersonRole.actor},
  ),
  PersonEntry(
    name: '侯孝贤',
    category: '华语',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '徐克',
    category: '华语',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '梁朝伟',
    category: '华语',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '巩俐',
    category: '华语',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '周润发',
    category: '华语',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '张国荣',
    category: '华语',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '章子怡',
    category: '华语',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '周星驰',
    category: '华语',
    roles: <PersonRole>{PersonRole.director, PersonRole.actor},
  ),
  PersonEntry(
    name: '刘德华',
    category: '华语',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '张曼玉',
    category: '华语',
    roles: <PersonRole>{PersonRole.actor},
  ),

  // ---------------------------------------------------------------- 欧美
  PersonEntry(
    name: '克里斯托弗·诺兰',
    category: '欧美',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '史蒂文·斯皮尔伯格',
    category: '欧美',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '马丁·斯科塞斯',
    category: '欧美',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '詹姆斯·卡梅隆',
    category: '欧美',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '昆汀·塔伦蒂诺',
    category: '欧美',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '大卫·芬奇',
    category: '欧美',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '雷德利·斯科特',
    category: '欧美',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '韦斯·安德森',
    category: '欧美',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '莱昂纳多·迪卡普里奥',
    category: '欧美',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '汤姆·汉克斯',
    category: '欧美',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '梅丽尔·斯特里普',
    category: '欧美',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '罗伯特·德尼罗',
    category: '欧美',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '布拉德·皮特',
    category: '欧美',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '凯特·布兰切特',
    category: '欧美',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '摩根·弗里曼',
    category: '欧美',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '娜塔莉·波特曼',
    category: '欧美',
    roles: <PersonRole>{PersonRole.actor},
  ),

  // ---------------------------------------------------------------- 日韩
  PersonEntry(
    name: '黑泽明',
    category: '日韩',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '宫崎骏',
    category: '日韩',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '是枝裕和',
    category: '日韩',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '奉俊昊',
    category: '日韩',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '朴赞郁',
    category: '日韩',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '李沧东',
    category: '日韩',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '北野武',
    category: '日韩',
    roles: <PersonRole>{PersonRole.director, PersonRole.actor},
  ),
  PersonEntry(
    name: '新海诚',
    category: '日韩',
    roles: <PersonRole>{PersonRole.director},
  ),
  PersonEntry(
    name: '宋康昊',
    category: '日韩',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '全度妍',
    category: '日韩',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '李秉宪',
    category: '日韩',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '裴斗娜',
    category: '日韩',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '役所广司',
    category: '日韩',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '长泽雅美',
    category: '日韩',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '渡边谦',
    category: '日韩',
    roles: <PersonRole>{PersonRole.actor},
  ),
  PersonEntry(
    name: '安藤樱',
    category: '日韩',
    roles: <PersonRole>{PersonRole.actor},
  ),
];

/// 按「类别 + 角色」取目录子集（保持目录声明顺序）
List<PersonEntry> personCatalogOf({
  required PersonRole role,
  String category = '全部',
}) {
  return kPersonCatalog
      .where(
        (p) =>
            p.roles.contains(role) &&
            (category == '全部' || p.category == category),
      )
      .toList();
}

// ------------------------------------------------------------------ 解析

/// suggest 命中的人物（`/j/subject_suggest?q=<name>` 的首个 `type=celebrity`）
class PersonSuggest {
  const PersonSuggest({
    required this.id,
    required this.name,
    this.subTitle = '',
    this.avatar = '',
  });

  final String id;
  final String name;
  final String subTitle;
  final String avatar;
}

/// 人物资料（`/v2/celebrity/<id>`）
class PersonProfile {
  const PersonProfile({
    required this.name,
    this.latinName = '',
    this.avatar = '',
    this.summary = '',
    this.url = '',
    this.facts = const <(String, String)>[],
  });

  final String name;
  final String latinName;
  final String avatar;
  final String summary;

  /// 豆瓣人物页（新 personage 形态）
  final String url;

  /// 结构化资料：`extra.info` 的 k-v（性别 / 出生日期 / 出生地 / IMDb 编号 …）
  final List<(String, String)> facts;
}

/// 人物代表作（`/v2/celebrity/<id>/works` 过滤后的单条作品）
class PersonWork {
  const PersonWork({
    required this.id,
    required this.title,
    required this.cover,
    required this.ratingValue,
    required this.ratingCount,
    required this.year,
    required this.url,
    required this.roles,
  });

  final String id;
  final String title;
  final String cover;
  final double ratingValue;
  final int ratingCount;
  final String year;
  final String url;
  final List<String> roles;

  /// 展示用评分串（无评分返回空串，UI 侧据此隐藏 ★）
  String get rate => ratingValue > 0 ? ratingValue.toStringAsFixed(1) : '';
}

/// 取首个非空字符串
String firstNonEmpty(Iterable<Object?> candidates) {
  for (final c in candidates) {
    final s = c?.toString() ?? '';
    if (s.isNotEmpty) return s;
  }
  return '';
}

double _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0;
}

int _asInt(Object? v) {
  if (v is num) return v.round();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

List<String> _strList(Object? v) =>
    (v as List?)
        ?.map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList() ??
    const <String>[];

/// 解析 suggest 响应：返回首个 `type=celebrity`，没有则返回 null。
///
/// 传入值允许是已解码的 `List`，也允许是未解码的 JSON 字符串（后者内部处理）。
PersonSuggest? parseCelebritySuggest(Object? raw) {
  final list = raw is List ? raw : null;
  if (list == null) return null;
  for (final e in list) {
    if (e is! Map) continue;
    if (e['type']?.toString() != 'celebrity') continue;
    final id = e['id']?.toString().trim() ?? '';
    final name = e['title']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) continue;
    return PersonSuggest(
      id: id,
      name: name,
      subTitle: e['sub_title']?.toString() ?? '',
      avatar: e['img']?.toString() ?? '',
    );
  }
  return null;
}

/// 解析人物资料。资料接口失败时调用方可以退化为 [PersonSuggest] 的少量信息。
PersonProfile parseCelebrityProfile(
  Object? raw, {
  String fallbackName = '',
  String fallbackAvatar = '',
  String fallbackLatinName = '',
}) {
  final m = raw is Map ? raw : const <String, dynamic>{};
  final cover = m['cover'] as Map?;
  final coverImg = m['cover_img'] as Map?;
  final extra = m['extra'] as Map?;
  final info = extra?['info'];

  final facts = <(String, String)>[];
  if (info is List) {
    for (final row in info) {
      if (row is! List || row.length < 2) continue;
      final k = row[0]?.toString().trim() ?? '';
      final v = row[1]?.toString().trim() ?? '';
      if (k.isEmpty || v.isEmpty) continue;
      facts.add((k, v));
    }
  }

  return PersonProfile(
    name: firstNonEmpty(<Object?>[m['title'], fallbackName]),
    latinName: firstNonEmpty(<Object?>[m['latin_title'], fallbackLatinName]),
    avatar: firstNonEmpty(<Object?>[
      (cover?['normal'] as Map?)?['url'],
      (cover?['large'] as Map?)?['url'],
      coverImg?['url'],
      fallbackAvatar,
    ]),
    summary: extra?['short_info']?.toString() ?? '',
    url: m['url']?.toString() ?? '',
    facts: facts,
  );
}

/// 解析作品列表：**按角色过滤 → 去重 → 过滤无封面 → 按评分/人数降序 → 截断**
///
/// - [role] 决定保留 `roles` 含「导演」还是「演员」的条目
/// - 去重按作品 id，同一作品多角色只保留一次
/// - 无封面（`cover_url` 与 `pic` 都为空）的条目直接丢弃，避免海报墙出现占位黑洞
List<PersonWork> parseCelebrityWorks(
  Object? raw, {
  required PersonRole role,
  int limit = 12,
}) {
  final m = raw is Map ? raw : const <String, dynamic>{};
  final list = m['works'];
  if (list is! List) return const <PersonWork>[];

  final hits = <PersonWork>[];
  final seen = <String>{};
  for (final e in list) {
    if (e is! Map) continue;
    final roles = _strList(e['roles']);
    final matched = roles.any(role.matches);
    if (!matched) continue;

    final work = e['work'];
    if (work is! Map) continue;
    final id = work['id']?.toString().trim() ?? '';
    final title = work['title']?.toString().trim() ?? '';
    if (id.isEmpty || title.isEmpty) continue;
    if (!seen.add(id)) continue;

    final pic = work['pic'] as Map?;
    final cover = firstNonEmpty(<Object?>[
      work['cover_url'],
      pic?['large'],
      pic?['normal'],
    ]);
    if (cover.isEmpty) continue;

    final rating = work['rating'] as Map?;
    hits.add(
      PersonWork(
        id: id,
        title: title,
        cover: cover,
        ratingValue: _asDouble(rating?['value']),
        ratingCount: _asInt(rating?['count']),
        year: work['year']?.toString() ?? '',
        url: work['url']?.toString() ?? '',
        roles: roles,
      ),
    );
  }

  hits.sort(comparePersonWorks);
  if (hits.length <= limit) return hits;
  return hits.take(limit).toList();
}

/// 代表作排序：**评分值降序 → 评分人数降序 → 年份降序**（最后按名字稳定兜底）
int comparePersonWorks(PersonWork a, PersonWork b) {
  final byRate = b.ratingValue.compareTo(a.ratingValue);
  if (byRate != 0) return byRate;
  final byCount = b.ratingCount.compareTo(a.ratingCount);
  if (byCount != 0) return byCount;
  final byYear = b.year.compareTo(a.year);
  if (byYear != 0) return byYear;
  return a.title.compareTo(b.title);
}
