/// 媒体标题解析：文件名 / 目录名 → 结构化影视信息。
///
/// 【纯 Dart、零依赖】不 import `dart:io`、不 import 任何 `package:*`，
/// 以便 `.tools/media_title_check.dart` 直接 import 源码做断言
/// （项目约定：`core/**` 的解析逻辑必须可被纯 Dart 护栏覆盖）。
///
/// 【为什么这个文件最重要】
/// 类 VidHub 体验的生死线是「裸文件名 → 影视元数据」的命中率（预研 R1 风险，等级高）。
/// 海报墙能不能配对、续播能不能合并，全部取决于本文件。因此它是 4.0 视频模块里
/// 唯一必须先建立准确率基线的模块，且刻意不依赖任何运行时环境。
///
/// 设计取舍：
/// 1. **先抽取后删除**。按「年份 → 季集 → 技术标签 → 压制组」的顺序，
///    每抽到一项就从原文里抹掉对应片段，剩下的才是标题。
///    比"先切词再过滤"更稳，因为中文标题没有空格可切。
/// 2. **中文与英文同一套规则**。边界判定用「非 ASCII 字母数字」而不是 `\b`，
///    因为 Dart RegExp 的 `\b` 按 ASCII 词字符算，中文会被当成非词字符，
///    导致 `\b国语\b` 永远匹配不上。
/// 3. **剧集在季集标记处截断**。`Breaking.Bad.S05E14.Ozymandias` 里
///    标题必须停在 S05E14 之前，否则剧名会被单集名污染。
library;

/// 媒体类型（与迁移 SQL 的 `media_video.type` 对齐：'movie' | 'tv'）
enum MediaTitleKind { movie, tv }

/// 解析结果。所有字段都可能为空——**解析失败必须显式可见，不许伪造**。
class MediaTitleInfo {
  const MediaTitleInfo({
    required this.title,
    required this.cleanTitle,
    required this.kind,
    this.year,
    this.season,
    this.episode,
    this.episodeEnd,
    this.episodeTitle,
    this.resolution,
    this.source,
    this.videoCodec,
    this.audioCodec,
    this.hdr,
    this.releaseGroup,
    this.languages = const <String>[],
    this.aliases = const <String>[],
    this.titleFromDirectory = false,
    this.confidence = 0,
  });

  /// 展示用标题（已剔除技术标签，保留原始大小写与中文标点）
  final String title;

  /// 匹配/去重用的归一化标题（小写、去标点、压空格）
  final String cleanTitle;

  final MediaTitleKind kind;

  final int? year;
  final int? season;
  final int? episode;

  /// 多集合并（如 S01E01-E03）的结束集号
  final int? episodeEnd;

  /// 单集标题（剧集专有，如 Ozymandias）
  final String? episodeTitle;

  final String? resolution;
  final String? source;
  final String? videoCodec;
  final String? audioCodec;

  /// HDR 标记（hdr10 / dolby vision / hlg / sdr），海报墙上要出画质角标
  final String? hdr;

  final String? releaseGroup;

  /// 识别到的语言/字幕标记（国语、粤语、中字…）
  final List<String> languages;

  /// 备选标题，供 TMDB 多轮检索（中英双名时尤其有用）
  final List<String> aliases;

  /// 标题是从父目录兜来的（文件名本身没带片名，命中率存疑）
  final bool titleFromDirectory;

  /// 0~1 的自信度，供 UI 决定要不要提示"请确认匹配"
  final double confidence;

  /// 作品级去重键：同一部电影的不同画质版本、同一部剧的各集都归到这里。
  /// 刻意用可读字符串而非哈希——便于排查，也避免本文件为了算 sha1 引入 crypto 依赖。
  String get contentKey {
    final y = year?.toString() ?? '';
    return '${kind.name}|$cleanTitle|$y';
  }

  /// 单集级去重键（仅剧集且识别到集号时非空）
  String? get episodeKey {
    if (kind != MediaTitleKind.tv || episode == null) return null;
    final s = season?.toString().padLeft(2, '0') ?? '00';
    final e = episode!.toString().padLeft(2, '0');
    return '${kind.name}|$cleanTitle|s${s}e$e';
  }

  bool get hasTitle => title.isNotEmpty;

  /// 是否值得拿去请求 TMDB（空标题或纯噪声不值得浪费配额）
  bool get worthMatching => hasTitle && cleanTitle.length >= 2;

  @override
  String toString() =>
      'MediaTitleInfo($contentKey'
      '${season != null ? ' S$season' : ''}'
      '${episode != null ? 'E$episode' : ''}'
      '${year != null ? ' ($year)' : ''}'
      ', title="$title", conf=${confidence.toStringAsFixed(2)})';
}

/// 视频扩展名（扫描器判定用，不含 ISO/镜像等非常规容器）
const Set<String> kVideoExtensions = <String>{
  'mp4',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'flv',
  'ts',
  'm2ts',
  'm4v',
  'webm',
  'rmvb',
  'rm',
  'mpg',
  'mpeg',
  '3gp',
  'ogv',
  'vob',
  'mts',
  'divx',
};

/// 解析媒体标题。
///
/// [input] 可以是完整路径也可以是纯文件名（`/` 与 `\` 都认）。
/// [pathHints] 为**由近及远**的父目录名序列，仅在文件名里挖不出片名时兜底。
class MediaTitleParser {
  const MediaTitleParser._();

  // ────────────────────────────── 抽取用正则 ──────────────────────────────

  /// 年份：只认 19xx / 20xx，两侧必须不是数字。
  /// 2160p / 1080p 天然不匹配（21、10 不在候选里）。
  ///
  /// **取最后一个匹配**：`2001太空漫游.1968.mkv` 里 2001 是片名的一部分、
  /// `Blade Runner 2049.2017` 里 2049 也是片名，只有靠后的才是发行年份。
  static final RegExp _yearRe = RegExp(
    r'(?:^|[^0-9])(19\d{2}|20\d{2})(?![0-9])',
  );

  /// 季集标记，按特异度从高到低。捕获组：1=季(S) 2=集(E) 3=结束集 4=季(第X季)
  /// 5=季(Season) 6=集(第X集) 7=集([01]) 8=集(EP12)
  ///
  /// **季/集序号必须支持中文数字**——`第一季`、`第十二集` 是中文剧集的主流写法，
  /// 只写 `\d` 会让这一类 100% 漏判，直接击穿中文命中率（预研 R1）。
  static final RegExp _seasonEpisodeRe = RegExp(
    r'[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})(?:[ ._-]?[Ee](\d{1,3}))?' // S01E02(-E04)
    r'|第\s*([0-9零一二三四五六七八九十]{1,4})\s*季' // 第1季 / 第一季
    r'|[Ss]eason\s*(\d{1,2})' // Season 1
    r'|第\s*([0-9零一二三四五六七八九十百]{1,4})\s*[集话話]' // 第12集 / 第三话
    r'|[\[\(（【]\s*(\d{1,3})\s*[\]\)）】]' // [01]（动漫常见）
    r'|(?:^|[ ._-])[Ee][Pp]?[ ._-]?(\d{1,3})(?=[ ._\-\[\]（(]|$)', // EP12 / E12
  );

  /// 分辨率
  static final RegExp _resolutionRe = RegExp(
    r'\b(\d{3,4}[x×]\d{3,4}|4320[pPiI]|2160[pPiI]|1440[pPiI]|1080[pPiI]|'
    r'720[pPiI]|576[pPiI]|480[pPiI]|360[pPiI]|240[pPiI]|[48][kK]|2[kK])\b',
  );

  /// 片源
  static final RegExp _sourceRe = RegExp(
    r'\b(bdremux|bdrip|brrip|blu-?ray|remux|web-?dl|webrip|hdrip|hdtvrip|hdtv|'
    r'dvdrip|dvd-?r|dvd|dvb|dsr|pdtv|dvdscr|screener|telecine|r5|cam|ts|tc)\b',
    caseSensitive: false,
  );

  /// 视频编码
  static final RegExp _videoCodecRe = RegExp(
    r'\b(x26[45]|h\.?26[45]|hevc|avc|xvid|divx|mpeg-?[24]|av1|vp9|vc-?1|'
    r'(?:10|8|12)-?bit|hi10p)\b',
    caseSensitive: false,
  );

  /// 音频编码
  static final RegExp _audioCodecRe = RegExp(
    r'\b(dts-?hd|dts-?x|dts|truehd|atmos|e-?ac-?3|ac-?3|aac|flac|opus|mp3|ogg|'
    r'auro-?3d|ddp5|dd\+?5|dd|5\.1|7\.1|2\.0)\b',
    caseSensitive: false,
  );

  /// HDR
  static final RegExp _hdrRe = RegExp(
    r'\b(hdr10\+|hdr10|hdr|hlg|dolby-?vision|dovi|sdr)\b',
    caseSensitive: false,
  );

  /// 语言/字幕标记（中英混排，不用 \b）
  static final RegExp _languageRe = RegExp(
    r'(国语|国配|普通话|粤语|日语|英语|韩语|法语|德语|双语|多国语言|中英字幕|中文字幕|'
    r'英文字幕|外挂字幕|内嵌字幕|无字幕|中字|简中|繁中|字幕|'
    r'mandarin|cantonese|jpsc|jptc|cht|chs|chi|eng|jpn|kor|ger|fre|spa)',
    caseSensitive: false,
  );

  // ────────────────────────────── 噪声词表 ──────────────────────────────
  // 从原文里"抹掉"的技术/版本标签。长词必须在短词前面，否则 `web` 会先吃掉 `web-dl`。

  static const List<String> _noiseWords = <String>[
    // 版本/修订
    'directors-cut', 'directors.cut', 'remastered', 'unrated', 'extended',
    'criterion', 'restored', 'upscaled', 'uncut', 'proper', 'repack',
    'rerip', 'internal', 'limited', 'complete', 'imax', 'open-matte',
    'hybrid', 'multi', 'rerip',
    // 片源（长→短）
    'blu-ray', 'bluray', 'bdremux', 'bdrip', 'brrip', 'bdmv', 'remux',
    'web-dl', 'webdl', 'webrip', 'hdtvrip', 'hdrip', 'hdtv', 'dvdrip',
    'dvdscr', 'screener', 'telecine', 'dvdr', 'dvd', 'bd', 'dvb', 'dsr',
    'pdtv', 'r5', 'cam', 'ts', 'tc',
    // 分辨率 / 画质
    'uhd', 'fhd', 'hd', 'sd', '4320p', '2160p', '1440p', '1080p', '1080i',
    '720p', '576p', '480p', '360p', '240p', '8k', '4k', '2k',
    // 编码
    'x264', 'x265', 'h.264', 'h264', 'h.265', 'h265', 'hevc', 'avc', 'xvid',
    'divx', 'mpeg-2', 'mpeg2', 'mpeg-4', 'mpeg4', 'av1', 'vp9', 'vc-1',
    'vc1', '10-bit', '10bit', '8-bit', '8bit', '12-bit', '12bit', 'hi10p',
    // HDR
    'hdr10+', 'hdr10', 'hdr', 'hlg', 'dolby-vision', 'dolbyvision', 'dovi',
    'sdr',
    // 音频（`5.1` / `7.1` 声道必须排在 `ddp5` 之前，
    // 否则 `DDP5.1` 会被切成两段，`ddp5` 被吃掉后残留一个孤立的 `1` 混进标题）
    'dts-hd', 'dts-x', 'dts', 'truehd', 'atmos', 'eac3', 'ac3', 'aac',
    'flac', 'opus', 'mp3', 'ogg', 'auro-3d', '5.1', '7.1', 'ddp5.1',
    'ddp5-1', 'dd5.1', 'dts5.1', 'ddp5', 'dd5', 'dd',
    // 中文噪声
    '高清', '超清', '蓝光', '抢先版', '枪版', '加长版', '导演剪辑版', '未删减',
    '修复版', '预告片', '花絮', '合集', '全集', '完结', '更新中', '正片',
  ];

  /// 噪声词里的 `.` `+` 是**字面量**（`h.264`、`ddp5.1`、`hdr10+`），
  /// 必须先转义再拼进正则，否则 `.` 会退化成"任意字符"通配符，
  /// 让 `h.264` 误吃掉 `hx264`，`hdr10+` 更是直接变成量词。
  static String _escapeToken(String s) =>
      s.replaceAll('.', r'\.').replaceAll('+', r'\+');

  /// 预拼接的噪声候选式。单独提出来是为了避开「插值里再嵌字符串字面量」——
  /// 那样 Dart 会把内层引号和外层的 `$` 解析打架。
  static final String _noiseAlternation = _noiseWords
      .map(_escapeToken)
      .join('|');

  /// 噪声匹配：左侧吃掉一个分隔字符（或行首），右侧用**前查**断言边界。
  /// 边界定义为"非 ASCII 字母数字"，因此中文、日文、标点都算边界——
  /// 这是让 `国语`/`中字` 这类中文噪声也能被抹掉的关键。
  static final RegExp _noiseRe = RegExp(
    '(?:^|[^A-Za-z0-9])((?:$_noiseAlternation))(?=[^A-Za-z0-9]|\$)',
    caseSensitive: false,
  );

  /// 语言标记匹配（同 noise 的边界策略，命中后从标题里抹掉但保留到 languages）
  static final RegExp _languageStripRe = RegExp(
    r'(?:^|[^A-Za-z0-9])((?:国语|国配|普通话|粤语|日语|英语|韩语|法语|德语|双语|'
    r'多国语言|中英字幕|中文字幕|英文字幕|外挂字幕|内嵌字幕|无字幕|中字|简中|繁中|'
    r'字幕|mandarin|cantonese|jpsc|jptc|cht|chs|chi|eng|jpn|kor|ger|fre|spa))'
    r'(?=[^A-Za-z0-9]|$)',
    caseSensitive: false,
  );

  /// 压制组：`-RARBG` / `-GROUP` 形式的尾缀
  static final RegExp _trailingGroupRe = RegExp(
    r'[ ._-]-([A-Za-z0-9][A-Za-z0-9_.]{1,20})$',
  );

  /// 纯数字的括号内容（动漫集号）
  static final RegExp _pureDigitsRe = RegExp(r'^\d{1,3}$');

  /// 目录名兜底时要跳过的分类目录
  static const Set<String> _categoryDirs = <String>{
    '电影',
    '电视剧',
    '剧集',
    '动漫',
    '动画',
    '纪录片',
    '综艺',
    '短片',
    '美剧',
    '日剧',
    '韩剧',
    '国产剧',
    '港剧',
    '台剧',
    '英剧',
    '新番',
    '剧场版',
    'movies',
    'movie',
    'tv',
    'tvshows',
    'tv shows',
    'series',
    'anime',
    'documentary',
    'documentaries',
    'docs',
    'videos',
    'video',
    'media',
    'shows',
    'season',
    'seasons',
    'collection',
    '未完成',
    '已完结',
    '连载中',
    '新建文件夹',
    'new folder',
    'untitled',
    '下载',
    'downloads',
  };

  // ────────────────────────────── 主入口 ──────────────────────────────

  /// 判断文件名是否为视频文件
  static bool isVideoFile(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return false;
    return kVideoExtensions.contains(name.substring(dot + 1).toLowerCase());
  }

  /// 取文件名（同时认 `/` 与 `\`）
  static String basename(String path) {
    var s = path.replaceAll('\\', '/');
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    final i = s.lastIndexOf('/');
    return i < 0 ? s : s.substring(i + 1);
  }

  /// 解析入口。
  static MediaTitleInfo parse(String input, {List<String>? pathHints}) {
    var work = _stripExtension(basename(input));

    // ① 括号里的内容先摘出来：可能是压制组、年份、动漫集号
    final bracketHits = <String>[];
    work = _extractBrackets(work, bracketHits);

    var year = _findYear(work) ?? _findYearIn(bracketHits);
    final languages = <String>{..._collect(_languageRe, work)};
    for (final b in bracketHits) {
      languages.addAll(_collect(_languageRe, b));
    }

    // ② 季集：命中即在标记处截断，标记之前是片名，之后是单集名
    var season = _seasonFrom(work);
    var episode = _episodeFrom(work);
    var episodeEnd = _episodeEndFrom(work);
    var episodeTitle = '';

    final seMatch = _seasonEpisodeRe.firstMatch(work);
    if (seMatch != null && seMatch.start > 0) {
      final before = work.substring(0, seMatch.start);
      final after = work.substring(seMatch.end);
      // 单集名 = 标记之后、第一个技术标签之前的那段可读文本
      episodeTitle = _cleanSegment(
        _stripTech(after)
            .replaceAll(RegExp(r'第\s*[0-9零一二三四五六七八九十百]{1,4}\s*[集话話]'), ' '),
      );
      work = before;
    } else if (seMatch != null) {
      // 标记就在开头（文件名以 S01E02 起手）→ 片名只能靠目录兜
      work = '';
    }

    // ③ 动漫 `[01]` 集号走括号通道
    if (episode == null) {
      for (final b in bracketHits) {
        if (_pureDigitsRe.hasMatch(b.trim())) {
          episode = int.tryParse(b.trim());
          break;
        }
      }
    }

    // ③b 尾缀集号：动漫常见 `片名 - 01`，没有 SxxExx 也没有第X集。
    //     只认 **≥2 位（零填充）或已确认有季**，否则 `Movie.Name.Part.2`
    //     这种电影分部会被误判成第 2 集——宁可漏，不可错配。
    if (episode == null) {
      final trimmed = work.trimRight();
      final tail = RegExp(r'[ ._-](\d{1,3})$').firstMatch(trimmed);
      final v = tail == null ? null : int.tryParse(tail.group(1)!);
      if (v != null &&
          v != year &&
          (tail!.group(1)!.length >= 2 || season != null)) {
        episode = v;
        work = trimmed.substring(0, tail.start);
      }
    }

    // ④ 技术标签抽取（记录到结果里，随后从标题中抹掉）
    final resolution =
        _firstGroup(_resolutionRe, work) ??
        _firstGroupIn(_resolutionRe, bracketHits);
    final source =
        _firstGroup(_sourceRe, work) ?? _firstGroupIn(_sourceRe, bracketHits);
    final videoCodec = _firstGroup(_videoCodecRe, work);
    final audioCodec = _firstGroup(_audioCodecRe, work);
    final hdr = _firstGroup(_hdrRe, work);

    // ⑤ 抹掉噪声与年份
    work = _stripLanguages(work);
    work = _stripNoise(work);
    work = _stripYear(work, year);

    // ⑥ 尾缀压制组
    String? releaseGroup;
    final grp = _trailingGroupRe.firstMatch(work);
    if (grp != null) {
      releaseGroup = grp.group(1);
      work = work.substring(0, grp.start);
    }
    releaseGroup ??= _guessGroup(bracketHits);

    // ⑦ 收口：清洗分隔符
    var title = _cleanSegment(work);

    // ⑧ 目录兜底
    var fromDir = false;
    if (_isWeakTitle(title) && pathHints != null) {
      final fallback = _titleFromHints(pathHints);
      if (fallback != null) {
        title = fallback;
        fromDir = true;
      }
    }

    // ⑨ 季/集的目录兜底（.. / Season 02 / xxx.mkv）
    if (season == null && pathHints != null) {
      season = _seasonFromHints(pathHints);
    }

    final kind = (season != null || episode != null)
        ? MediaTitleKind.tv
        : MediaTitleKind.movie;

    final clean = _normalizeTitle(title);
    final aliases = _buildAliases(title, clean);

    return MediaTitleInfo(
      title: title,
      cleanTitle: clean,
      kind: kind,
      year: year,
      season: season,
      episode: episode,
      episodeEnd: episodeEnd,
      episodeTitle: episodeTitle.isEmpty ? null : episodeTitle,
      resolution: resolution?.toLowerCase(),
      source: source?.toLowerCase(),
      videoCodec: videoCodec?.toLowerCase(),
      audioCodec: audioCodec?.toLowerCase(),
      hdr: hdr?.toLowerCase(),
      releaseGroup: releaseGroup,
      languages: languages.toList()..sort(),
      aliases: aliases,
      titleFromDirectory: fromDir,
      confidence: _score(
        title: title,
        year: year,
        season: season,
        episode: episode,
        resolution: resolution,
        fromDir: fromDir,
      ),
    );
  }

  // ────────────────────────────── 内部实现 ──────────────────────────────

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return name; // 无扩展名
    if (dot == 0) return ''; // 以点起手（`.mkv`）：没有文件名，只有扩展名
    final ext = name.substring(dot + 1).toLowerCase();
    return kVideoExtensions.contains(ext) ? name.substring(0, dot) : name;
  }

  /// 把括号内容摘出来放进 [out]，返回去掉括号及其内容的文本。
  static String _extractBrackets(String text, List<String> out) {
    final buf = StringBuffer();
    final open = <String>[];
    final inner = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if ('[{（【'.contains(ch)) {
        open.add(ch);
        inner.clear();
        continue;
      }
      if (']}）】'.contains(ch)) {
        if (open.isNotEmpty) {
          open.removeLast();
          final s = inner.toString().trim();
          if (s.isNotEmpty) out.add(s);
          inner.clear();
          continue;
        }
      }
      if (open.isNotEmpty) {
        inner.write(ch);
      } else {
        buf.write(ch);
      }
    }
    // 未闭合的括号：内容当作普通文本吐回，避免吞掉片名
    if (open.isNotEmpty && inner.isNotEmpty) {
      buf.write(inner.toString());
    }
    return buf.toString();
  }

  static int? _findYear(String s) {
    int? last;
    for (final m in _yearRe.allMatches(s)) {
      final v = int.tryParse(m.group(1)!);
      if (v != null && v >= 1900 && v <= 2100) last = v;
    }
    return last;
  }

  static int? _findYearIn(List<String> parts) {
    int? last;
    for (final p in parts) {
      final y = _findYear(p);
      if (y != null) last = y;
    }
    return last;
  }

  /// 季号 / 集号一律扫**全部匹配**而不是首个匹配：
  /// `第1季第2集`、`S01E02-E03` 这类一段文本里同时含季和集的写法，
  /// 只取 firstMatch 会漏掉后半段。
  static int? _seasonFrom(String s) {
    for (final m in _seasonEpisodeRe.allMatches(s)) {
      final v = m.group(1) ?? m.group(4) ?? m.group(5);
      if (v != null) return _toInt(v);
    }
    return null;
  }

  static int? _episodeFrom(String s) {
    for (final m in _seasonEpisodeRe.allMatches(s)) {
      final v = m.group(2) ?? m.group(6) ?? m.group(7) ?? m.group(8);
      if (v != null) return _toInt(v);
    }
    return null;
  }

  /// 阿拉伯数字或中文数字 → int。`第一季`→1、`第十二集`→12、`十`→10。
  static int? _toInt(String s) {
    final direct = int.tryParse(s);
    if (direct != null) return direct;
    const digits = <String, int>{
      '零': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (s.contains('十')) {
      final parts = s.split('十');
      final tens = parts[0].isEmpty
          ? 1
          : (digits[parts[0]] ?? int.tryParse(parts[0]));
      final ones = (parts.length > 1 && parts[1].isNotEmpty)
          ? (digits[parts[1]] ?? int.tryParse(parts[1]))
          : 0;
      if (tens == null || ones == null) return null;
      return tens * 10 + ones;
    }
    if (s.length == 1) return digits[s];
    var n = 0;
    for (final ch in s.split('')) {
      final d = digits[ch];
      if (d == null) return null;
      n = n * 10 + d;
    }
    return n;
  }

  static int? _episodeEndFrom(String s) {
    for (final m in _seasonEpisodeRe.allMatches(s)) {
      if (m.group(3) != null) return int.tryParse(m.group(3)!);
    }
    return null;
  }

  /// 从父目录序列里找季号（`Season 02` / `S02` / `第2季`）
  static int? _seasonFromHints(List<String> hints) {
    for (final h in hints) {
      final m = RegExp(
        r'(?:^|[ _.-])(?:season|s)\s*(\d{1,2})(?=$|[ _.\-])',
        caseSensitive: false,
      ).firstMatch(h);
      if (m != null) return int.tryParse(m.group(1)!);
      final cn = RegExp(r'第\s*(\d{1,2})\s*季').firstMatch(h);
      if (cn != null) return int.tryParse(cn.group(1)!);
    }
    return null;
  }

  static List<String> _collect(RegExp re, String s) =>
      re.allMatches(s).map((m) => m.group(1)!.toLowerCase()).toSet().toList();

  static String? _firstGroup(RegExp re, String s) {
    final m = re.firstMatch(s);
    return m?.group(1);
  }

  static String? _firstGroupIn(RegExp re, List<String> parts) {
    for (final p in parts) {
      final v = _firstGroup(re, p);
      if (v != null) return v;
    }
    return null;
  }

  /// 抹掉语言/字幕标记。
  /// **必须循环**：`国语中字` 这种连排写法，第一遍只能吃掉 `国语`
  /// （因为 `中字` 的左侧边界字符 `语` 已被上一处匹配消费掉，
  /// `replaceAllMapped` 不会回退重扫），第二遍才能吃到 `中字`。
  static String _stripLanguages(String s) {
    var out = s;
    for (var i = 0; i < 3; i++) {
      final next = out.replaceAllMapped(
        _languageStripRe,
        (m) => m.group(0)!.startsWith(m.group(1)!) ? '' : m.group(0)![0],
      );
      if (next == out) break;
      out = next;
    }
    return out;
  }

  /// 抹掉技术/版本噪声。左侧吃掉的分隔符要还回去，否则会粘连相邻词。
  static String _stripNoise(String s) {
    var out = s;
    for (var i = 0; i < 4; i++) {
      final next = out.replaceAllMapped(_noiseRe, (m) {
        final whole = m.group(0)!;
        final token = m.group(1)!;
        return whole.substring(0, whole.length - token.length);
      });
      if (next == out) break;
      out = next;
    }
    return out;
  }

  static String _stripYear(String s, int? year) {
    if (year == null) return s;
    return s.replaceFirst('$year', ' ');
  }

  /// 只抹技术标签（用于从"季集标记之后"抽单集名）
  static String _stripTech(String s) => _stripLanguages(_stripNoise(s));

  /// 括号内容里猜压制组：全 ASCII、无空格、长度 2~20
  static String? _guessGroup(List<String> brackets) {
    for (final b in brackets) {
      final t = b.trim();
      if (t.length < 2 || t.length > 20) continue;
      if (_pureDigitsRe.hasMatch(t)) continue;
      if (RegExp(r'^[A-Za-z0-9._\-]+$').hasMatch(t)) return t;
    }
    return null;
  }

  /// 清洗分隔符：去首尾残留、压重复、去孤立短横
  static String _cleanSegment(String s) {
    var t = s;
    t = t.replaceAll(RegExp(r'[._]+'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    t = t.replaceAll(RegExp(r'(?:^|\s)-+(?:\s|$)'), ' ');
    t = t.replaceAll(RegExp(r'^[-\s]+|[-\s]+$'), '');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// 归一化：小写、去标点、压空格
  static String _normalizeTitle(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[：:·|/\\,，。.!！?？~～\-_+]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// 标题是否"太弱"，需要目录兜底
  static bool _isWeakTitle(String t) {
    if (t.trim().isEmpty) return true;
    final letters = RegExp(r'[A-Za-z0-9\u4e00-\u9fff]').allMatches(t).length;
    return letters < 2;
  }

  static String? _titleFromHints(List<String> hints) {
    for (final h in hints) {
      final t = _cleanSegment(_stripTech(h));
      if (t.isEmpty) continue;
      final lower = t.toLowerCase();
      if (_categoryDirs.contains(lower)) continue;
      // `Season 01` 这类季目录不是片名
      if (RegExp(
        r'^(?:season|s)\s*\d{1,2}$',
        caseSensitive: false,
      ).hasMatch(t)) {
        continue;
      }
      if (RegExp(r'^第\s*\d{1,2}\s*季$').hasMatch(t)) continue;
      return t;
    }
    return null;
  }

  /// 中英双名拆出备选（供 TMDB 多轮检索：先搜中文，miss 再搜英文）。
  ///
  /// 不按标点逐词拆——那样 `Spider-Man.No.Way.Home` 会碎成 5 个无意义 alias。
  /// 正确做法是**按文字体系拆成两整块**：CJK 一块、拉丁一块，各自归一化。
  static List<String> _buildAliases(String title, String clean) {
    if (clean.isEmpty) return const <String>[];
    final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(title);
    final hasLatin = RegExp(r'[A-Za-z]{2,}').hasMatch(title);
    if (!hasCjk || !hasLatin) return <String>[clean];

    final cjk = RegExp(r'[\u4e00-\u9fff]+')
        .allMatches(title)
        .map((m) => m.group(0)!)
        .join();
    final latin = _normalizeTitle(
      title.replaceAll(RegExp(r'[\u4e00-\u9fff]+'), ' '),
    );

    final out = <String>[clean];
    for (final c in <String>[_normalizeTitle(cjk), latin]) {
      if (c.length >= 2 && !out.contains(c)) out.add(c);
    }
    return out;
  }

  static double _score({
    required String title,
    required int? year,
    required int? season,
    required int? episode,
    required String? resolution,
    required bool fromDir,
  }) {
    var s = 0.0;
    if (title.isNotEmpty) s += 0.40;
    if (year != null) s += 0.20;
    if (season != null || episode != null) s += 0.20;
    if (resolution != null) s += 0.10;
    if (fromDir) s -= 0.30;
    return s.clamp(0.0, 1.0);
  }
}
