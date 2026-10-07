/// 媒体列表分组归类：平铺文件列表 → 「作品 → 集/版本」两级结构。
///
/// 【纯 Dart、零依赖】不 import `dart:io`、不 import 任何 `package:*`，
/// 以便 `.tools/media_grouping_check.dart` 直接 import 源码做断言
/// （项目约定：`core/**` 的解析/归类逻辑必须可被纯 Dart 护栏覆盖）。
///
/// 【解决什么缺陷】B1-3：同集电视剧或同系列电影直接平铺显示原名，
/// 41 集剧名完全相同分不清集数。分组键用 [MediaTitleInfo.contentKey]
/// （kind|cleanTitle|year）——同一部剧的各集、同一部电影的不同画质版本
/// 天然聚合到一起；集与集之间靠 season/episode 排序出次序。
///
/// 【刻意不做】拼音排序（无依赖可用，但当前标题混合中英，按码位排已够用）；
/// TMDB 元数据合并（那是海报墙批次的事，本文件只对既有解析结果归类）。
library;

import 'media_title_parser.dart';

/// 分组输入项：UI 侧把扫描结果映射成它（文件 + 解析信息）。
///
/// 刻意自带 path/name/size 而不引用 `LocalVideoFile`——后者在
/// features 层且 import dart:io，会击穿本文件的零依赖约束。
class MediaGroupItem {
  const MediaGroupItem({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.info,
  });

  final String path;
  final String name;
  final int sizeBytes;
  final MediaTitleInfo info;
}

/// 一个「作品」分组：一部剧（含全部集）/ 一部电影（可能多版本）。
class MediaGroup {
  const MediaGroup({
    required this.contentKey,
    required this.title,
    required this.kind,
    this.year,
    required this.items,
  });

  /// 聚合键（= 首项 info.contentKey），供 UI 的展开态记忆用
  final String contentKey;
  final String title;
  final MediaTitleKind kind;
  final int? year;
  final List<MediaGroupItem> items;

  bool get isSingle => items.length == 1;

  /// 组标题：片名 + 年份（与现有 `_MediaEntry.display` 口径一致）
  String get label {
    final StringBuffer sb = StringBuffer(title);
    if (year != null) sb.write(' ($year)');
    return sb.toString();
  }

  /// 剧集组的副标题：`S01 · 12 集` / `共 41 集`（未识别到季）；电影组返回空串。
  String get subtitle {
    if (kind != MediaTitleKind.tv || items.length < 2) return '';
    final seasons = items.map((e) => e.info.season ?? 0).toSet().toList()
      ..sort();
    final known = seasons.where((s) => s > 0).toList();
    if (known.isEmpty) return '共 ${items.length} 集';
    final head = known.length == 1 ? 'S${known.first}' : 'S${known.first}+';
    return '$head · ${items.length} 集';
  }
}

/// 分组主入口。
///
/// 排序约定（确定性，护栏可断言）：
/// * 组：剧集在前、电影在后；同为剧集按标题（不区分大小写）、再按年份；
/// * 组内：按 (season, episode, 文件名) 升序——集号缺失的排在该季末尾。
List<MediaGroup> groupMedia(List<MediaGroupItem> items) {
  final Map<String, List<MediaGroupItem>> buckets =
      <String, List<MediaGroupItem>>{};
  for (final MediaGroupItem it in items) {
    buckets.putIfAbsent(it.info.contentKey, () => <MediaGroupItem>[]).add(it);
  }

  final List<MediaGroup> groups = buckets.entries.map((
    MapEntry<String, List<MediaGroupItem>> e,
  ) {
    final List<MediaGroupItem> list = e.value..sort(_byEpisode);
    final MediaTitleInfo head = list.first.info;
    return MediaGroup(
      contentKey: e.key,
      title: head.hasTitle ? head.title : list.first.name,
      kind: head.kind,
      year: head.year,
      items: list,
    );
  }).toList()..sort(_groupsFirst);

  return groups;
}

/// 组内排序：季 → 集 → 文件名。集号未知视作 +∞（排在该季末尾，不冒充第 0 集）。
int _byEpisode(MediaGroupItem a, MediaGroupItem b) {
  final int sa = a.info.season ?? 0;
  final int sb = b.info.season ?? 0;
  if (sa != sb) return sa.compareTo(sb);
  final int? ea = a.info.episode;
  final int? eb = b.info.episode;
  if (ea == null && eb == null) return a.name.compareTo(b.name);
  if (ea == null) return 1;
  if (eb == null) return -1;
  if (ea != eb) return ea.compareTo(eb);
  return a.name.compareTo(b.name);
}

/// 组间排序：剧集优先 → 标题（忽略大小写）→ 年份 → 键名兜底。
int _groupsFirst(MediaGroup a, MediaGroup b) {
  if (a.kind != b.kind) {
    return a.kind == MediaTitleKind.tv ? -1 : 1;
  }
  final int byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
  if (byTitle != 0) return byTitle;
  final int ya = a.year ?? 0;
  final int yb = b.year ?? 0;
  if (ya != yb) return ya.compareTo(yb);
  return a.contentKey.compareTo(b.contentKey);
}

/// 单集行标题：`S01E02` / `E12` / 无集号时回落文件名（宁可朴素，不可编造）。
String episodeLabel(MediaGroupItem it) {
  final MediaTitleInfo i = it.info;
  final String? s = i.season?.toString().padLeft(2, '0');
  final String? e = i.episode?.toString().padLeft(2, '0');
  if (s != null && e != null) return 'S${s}E$e';
  if (e != null) return 'E$e';
  return it.name;
}

/// 单集副行：单集名优先，缺失回落文件名。
String episodeSubtitle(MediaGroupItem it) {
  final String? t = it.info.episodeTitle;
  if (t != null && t.isNotEmpty) return t;
  return it.name;
}
