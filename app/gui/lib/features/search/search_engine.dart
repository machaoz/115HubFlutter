import 'dart:convert' show LineSplitter;

import '../../sources/source.dart';

/// 搜索结果治理流水线：清洗 → 归一化 → 去重 → 排序
/// 【口径严格对齐 Electron 版】normalize.ts / dedupe.ts / rank.ts
/// 任何改动都必须在双端同步，否则会导致「同关键词结果集不一致」验收失败。

const int _day = 86400000;
const int _recencyWindowMs = 365 * _day;
const double _sizePct = 0.05;

// ------------------------------------------------------------------ 标题清洗

String _stripWatermark(String s) => s
    .replaceAll(RegExp(r'[\[【(（][^\]】)）]{0,80}@[^\]】)）]{0,120}[\]】)）]'), ' ')
    .replaceAll(
        RegExp(
            r'\[(?:www\.)?[a-z0-9][a-z0-9.-]{0,60}\.(?:com|net|org|cc|tv|xyz|top|vip|site)\]',
            caseSensitive: false),
        ' ')
    .replaceAll(RegExp(r'(?:来自|发布自|压制自)\s*[:：]?\s*\S{1,30}'), ' ')
    .replaceAll(RegExp(r'\s{2,}'), ' ')
    .trim();

/// 全角转半角 + NFKC 归一（Dart String 本身为 Unicode，主要处理全角区间）
String _toHalfWidth(String s) {
  final sb = StringBuffer();
  for (final unit in s.codeUnits) {
    if (unit >= 0xFF01 && unit <= 0xFF5E) {
      sb.writeCharCode(unit - 0xFEE0);
    } else if (unit == 0x3000) {
      sb.write(' ');
    } else {
      sb.writeCharCode(unit);
    }
  }
  return sb.toString();
}

String cleanTitle(String raw) {
  var v = _toHalfWidth(raw);
  v = _stripWatermark(v);
  v = v.replaceAll(RegExp(r'[\t\r\n]+'), ' ').replaceAll(RegExp(r'\s{2,}'), ' ');
  return v.replaceAll(RegExp(r'^[\s\-_·|:：，,。]+|[\s\-_·|:：，,。]+$'), '');
}

// ------------------------------------------------------------------ 质量标签

const List<(String, String, int)> _resOrder = <(String, String, int)>[
  ('2160p', r'2160p|\b4k\b', 4),
  ('1080p', r'1080p|\b1080\b', 3),
  ('1080i', r'1080i', 2),
  ('720p', r'\b720p\b', 2),
  ('480p', r'\b480p\b', 1),
];

String? parseResolution(String t) {
  for (final r in _resOrder) {
    if (RegExp(r.$2, caseSensitive: false).hasMatch(t)) return r.$1;
  }
  return null;
}

int resWeight(String? res) {
  for (final r in _resOrder) {
    if (r.$1 == res) return r.$3;
  }
  return 0;
}

String? parseCodec(String t) {
  if (RegExp(r'h\.?265|hevc|x265', caseSensitive: false).hasMatch(t)) return 'HEVC';
  if (RegExp(r'h\.?264|avc|x264', caseSensitive: false).hasMatch(t)) return 'x264';
  if (RegExp(r'av1', caseSensitive: false).hasMatch(t)) return 'AV1';
  return null;
}

(int?, int?) parseSeasonEpisode(String t) {
  final m = RegExp(r'[Ss](\d{1,2})[Ee](\d{1,3})').firstMatch(t);
  if (m != null) {
    return (int.tryParse(m.group(1)!), int.tryParse(m.group(2)!));
  }
  final s = RegExp(r'[Ss](\d{1,2})\b').firstMatch(t);
  if (s != null) return (int.tryParse(s.group(1)!), null);
  return (null, null);
}

const Map<String, int> _unitBytes = <String, int>{
  'b': 1,
  'kb': 1024,
  'mb': 1024 * 1024,
  'gb': 1024 * 1024 * 1024,
  'tb': 1024 * 1024 * 1024 * 1024,
};

int? parseSizeBytes(String text, {int? directBytes}) {
  if (directBytes != null && directBytes > 0) return directBytes;
  int? best;
  for (final m in RegExp(r'(\d+(?:\.\d+)?)\s*(b|kb|mb|gb|tb)', caseSensitive: false)
      .allMatches(text)) {
    final n = double.tryParse(m.group(1)!);
    final u = _unitBytes[m.group(2)!.toLowerCase()];
    if (n == null || u == null) continue;
    final b = (n * u).round();
    if (b > 0 && (best == null || b > best)) best = b;
  }
  return best;
}

/// 从 magnet URI / 裸 40 位 hex 中提取 infohash
String? extractInfohash(String? magnet) {
  if (magnet == null || magnet.isEmpty) return null;
  final m = RegExp(r'urn:btih:([0-9a-fA-F]{40})').firstMatch(magnet);
  if (m != null) return m.group(1)!.toLowerCase();
  final hex = RegExp(r'^[0-9a-fA-F]{40}$').stringMatch(magnet.trim());
  return hex?.toLowerCase();
}

// ------------------------------------------------------------------ 归一化

ResourceItem normalize(RawItem raw, SourceLite source) {
  final title = cleanTitle(raw.title);
  final lower = title.toLowerCase();
  final infohash = extractInfohash(raw.magnet);
  final se = parseSeasonEpisode(raw.title);

  final publishAt = raw.publishAt;

  String dedupeKey;
  String? magnetUri = raw.magnet;
  if (source.kind == ResourceKind.magnet) {
    if (infohash != null) {
      magnetUri ??= 'magnet:?xt=urn:btih:$infohash';
      dedupeKey = 'm:$infohash';
    } else {
      dedupeKey = 't:$lower';
    }
  } else {
    final sha = raw.sha1?.toLowerCase();
    if (sha != null && RegExp(r'^[0-9a-f]{40}$').hasMatch(sha)) {
      dedupeKey = 'p:$sha';
    } else if (raw.shareCode != null && raw.shareCode!.isNotEmpty) {
      dedupeKey = 's:${raw.shareCode!.trim()}';
    } else if (raw.secLink != null && raw.secLink!.isNotEmpty) {
      dedupeKey = '115:${raw.secLink}';
    } else {
      dedupeKey = 't:$lower';
    }
  }

  final id = switch (source.id) {
    '' => lower,
    _ => '${source.id}:$dedupeKey',
  };

  return ResourceItem(
    id: id,
    kind: source.kind,
    title: title,
    cleanTitle: lower,
    dedupeKey: dedupeKey,
    sourceId: source.id,
    magnetUri: infohash != null ? (magnetUri ?? 'magnet:?xt=urn:btih:$infohash') : raw.magnet,
    infohash: infohash,
    sha1: raw.sha1?.toLowerCase(),
    secLink: raw.secLink,
    shareCode: raw.shareCode,
    receiveCode: raw.receiveCode,
    sizeBytes: raw.sizeBytes ??
        parseSizeBytes(raw.sizeText ?? raw.title, directBytes: raw.sizeBytes),
    fileCount: raw.fileCount,
    publishAt: publishAt,
    hotness: raw.hotness ?? 0,
    detailUrl: raw.detailUrl,
    resolution: parseResolution(raw.title),
    codec: parseCodec(raw.title),
    season: se.$1,
    episode: se.$2,
  );
}

/// 强身份键（m:/p:/s:/115:）才有跨源合并价值
bool hasStrongRef(ResourceItem it) => !it.dedupeKey.startsWith('t:');

// ------------------------------------------------------------------ 分桶去重

/// 去重并入组：优先强身份键；否则同 kind + 同 cleanTitle + 容量 ±5%
List<List<ResourceItem>> dedupe(List<ResourceItem> items) {
  final groups = <List<ResourceItem>>[];
  for (final it in items) {
    var hit = false;
    for (final g in groups) {
      final m = g.first;
      final strongHit = m.dedupeKey == it.dedupeKey;
      final weakHit = m.kind == it.kind &&
          m.cleanTitle == it.cleanTitle &&
          _sizeClose(m.sizeBytes, it.sizeBytes);
      if (strongHit || weakHit) {
        // 后到者带更强身份键而主条目没有 → 主条目升级
        if (!strongHit && !hasStrongRef(m) && hasStrongRef(it)) {
          g.insert(0, it);
        } else {
          g.add(it);
        }
        hit = true;
        break;
      }
    }
    if (!hit) groups.add(<ResourceItem>[it]);
  }
  return groups;
}

bool _sizeClose(int? a, int? b) {
  if (a == null || b == null) return true; // 双侧未知容量视为相等
  if (a == 0 || b == 0) return true;
  return ((a - b).abs() / a) <= _sizePct;
}

// ------------------------------------------------------------------ 综合排序

Set<String> _tokenize(String s) => LineSplitter()
    .convert(s.replaceAll(RegExp(r'[\s\-_·，。、（）()\[\]【】:：/\\|]+'), '\n'))
    .map((e) => e.toLowerCase().trim())
    .where((e) => e.isNotEmpty)
    .toSet();

double _relevance(Set<String> itemTokens, Set<String> queryTokens) {
  if (queryTokens.isEmpty) return 0;
  var hit = 0;
  for (final q in queryTokens) {
    var found = itemTokens.contains(q);
    if (!found) {
      for (final t in itemTokens) {
        if ((t.contains(q) || q.contains(t)) && t.isNotEmpty) {
          found = true;
          break;
        }
      }
    }
    if (found) hit++;
  }
  return hit / queryTokens.length;
}

double _recencyBonus(int? publishAt) {
  if (publishAt == null) return 0;
  final age = DateTime.now().millisecondsSinceEpoch - publishAt;
  if (age < 0 || age > _recencyWindowMs) return 0;
  return (1 - age / _recencyWindowMs).clamp(0.0, 1.0);
}

double _qualityBonus(ResourceItem m) {
  var b = 0.0;
  if (m.resolution == '2160p') b += 2;
  if (m.resolution == '1080p') b += 1.5;
  if (m.codec == 'HEVC' || m.codec == 'AV1') b += 1;
  return b;
}

/// 组内代表-growth：取同组中 hotness 最高者作为展示条目
ResourceItem _representative(List<ResourceItem> g) {
  var best = g.first;
  for (final it in g) {
    if (it.hotness > best.hotness) best = it;
  }
  return best;
}

/// group -> score
double scoreGroup(List<ResourceItem> g, Set<String> queryTokens) {
  final m = _representative(g);
  final rel = _relevance(_tokenize(m.cleanTitle), queryTokens);
  return rel * 100 + m.hotness * 0.12 + _recencyBonus(m.publishAt) * 8 + _qualityBonus(m);
}

/// 排序（稳定：同分 → hotness → 原序 → id 字典序，避免流式刷新跳动）
List<List<ResourceItem>> rankGroups(
    List<List<ResourceItem>> groups, Set<String> queryTokens) {
  final indexed = groups.toList().asMap().entries.toList();
  final scored = indexed.map((e) => (e.key, scoreGroup(e.value, queryTokens), e.value)).toList();
  scored.sort((a, b) {
    final c = b.$2.compareTo(a.$2);
    if (c != 0) return c;
    final h = _representative(b.$3).hotness.compareTo(_representative(a.$3).hotness);
    if (h != 0) return h;
    final i = a.$1.compareTo(b.$1);
    if (i != 0) return i;
    return _representative(a.$3).id.compareTo(_representative(b.$3).id);
  });
  return scored.map((e) => e.$3).toList();
}
