import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/image_loader.dart';
import '../../features/search/search_engine.dart';
import '../../features/search/search_seed.dart';
import '../../sources/adapters.dart';
import '../../sources/source.dart';
import '../../state/providers.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'person_board.dart' show PersonBoard;
import 'person_catalog.dart' show kPersonCategories, PersonRole;

const String _doubanBase = 'https://movie.douban.com';
const String _doubleRexxar = 'https://m.douban.com/rexxar/api/v2/movie';
const String kDoubanReferer = 'https://movie.douban.com/';
const String kDoubanUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 豆瓣请求 Dio 工厂（海报墙与人物分类共用，**代理 / 超时口径只有一个来源**）
///
/// 明文响应（ResponseType.plain）：豆瓣部分接口会返回带 BOM/非标准 JSON，
/// 交给调用方自行 jsonDecode，避免 Dio 内置解码直接抛错。
Dio newDoubanDio({required String proxy, required int timeoutMs}) {
  final d = Dio(
    BaseOptions(
      connectTimeout: Duration(milliseconds: timeoutMs),
      receiveTimeout: Duration(milliseconds: timeoutMs),
      responseType: ResponseType.plain,
    ),
  );
  if (proxy.isNotEmpty) {
    d.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final c = HttpClient();
        c.findProxy = (uri) => 'PROXY $proxy';
        return c;
      },
    );
  }
  return d;
}

/// 剧集侧唯一有效的「全量」tag（豆瓣 tv 侧实测，见 `doubanTagCandidates` 注释）
const String kDoubanTvAllTag = '热门';

/// 候选 tag 链：**首个有数据的返回，若全部为空则由调用方取最后结果**
///
/// 豆瓣 `/j/search_subjects` 实测矩阵（2026-09）：
/// - movie：热门 / 最新 / 豆瓣高分 + 全部细分 tag 均有数据
/// - tv：**只有 tv 专属分类 tag 与「热门」有效**；「最新」「豆瓣高分」「电视剧」
///   乃至空 tag 一律返回 0 条
///
/// 因此「剧集 → 全部」绝不能沿用 sort 作 tag（旧实现正是这样，导致页面空白）：
/// tv 侧固定走全量 tag「热门」，排序仍由 `sort` 参数控制，
/// 用户感知的「最新 / 高分」维度不受影响。
List<String> doubanTagCandidates(String type, String sort, String category) {
  final allTag = type == 'tv' ? kDoubanTvAllTag : sort;
  if (category == '全部' || category == allTag) return <String>[allTag];
  return <String>[category, allTag];
}

/// 海报条目
class WallSubject {
  const WallSubject({
    required this.id,
    required this.title,
    required this.rate,
    required this.cover,
    required this.url,
  });

  final String id;
  final String title;
  final String rate;
  final String cover;
  final String url;
}

/// 条目详情
class WallDetail {
  const WallDetail({
    required this.title,
    required this.originalTitle,
    required this.year,
    required this.rate,
    required this.ratingCount,
    required this.cover,
    required this.url,
    required this.genres,
    required this.countries,
    required this.directors,
    required this.actors,
    required this.intro,
    required this.source,
  });

  final String title;
  final String originalTitle;
  final String year;
  final String rate;
  final int ratingCount;
  final String cover;
  final String url;
  final List<String> genres;
  final List<String> countries;
  final List<String> directors;
  final List<String> actors;
  final String intro;
  final String source; // 'detail' | 'abstract'
}

/// 豆瓣取数（口径严格对齐 Electron 版 metadata/douban.ts）
/// - 海报墙：GET {base}/j/search_subjects
/// - 详情主源：GET m.douban.com/rexxar/api/v2/movie/{sid}
/// - 详情降级：GET {base}/j/subject_abstract
class DoubanService {
  DoubanService({this.proxy = '', this.timeoutMs = 8000});

  /// 可热更新（跟随「设置 - 网络」变化），使 30 分钟结果缓存跨请求复用
  String proxy;
  int timeoutMs;

  final Map<String, List<WallSubject>> _cache = <String, List<WallSubject>>{};
  final Map<String, DateTime> _cacheAt = <String, DateTime>{};

  /// 手动刷新入口：清空结果缓存（不影响实例的其他请求）
  void invalidate() {
    _cache.clear();
    _cacheAt.clear();
  }

  Dio get _dio => newDoubanDio(proxy: proxy, timeoutMs: timeoutMs);

  Map<String, String> get _headers => <String, String>{
    'user-agent': kDoubanUa,
    'referer': kDoubanReferer,
    'accept': 'application/json, text/plain, */*',
    'accept-language': 'zh-CN,zh;q=0.9',
  };

  Future<List<WallSubject>> wall({
    required String kind, // 影视 | 剧集
    required String sort, // 热门 | 最新 | 豆瓣高分
    String category = '全部',
    int limit = 24,
    int pageStart = 0,
  }) async {
    final type = kind == '剧集' ? 'tv' : 'movie';
    final sorted = switch (sort) {
      '最新' => 'time',
      '豆瓣高分' => 'rank',
      _ => 'recommend',
    };
    final attempts = doubanTagCandidates(type, sort, category);

    final key = '$kind|$sorted|${attempts.join('>')}|$limit|$pageStart';
    final cachedAt = _cacheAt[key];
    if (cachedAt != null &&
        DateTime.now().difference(cachedAt).inMinutes < 30 &&
        _cache.containsKey(key)) {
      return _cache[key]!;
    }

    String buildUri(String tg) => Uri.parse('$_doubanBase/j/search_subjects')
        .replace(
          queryParameters: <String, String>{
            'type': type,
            'tag': tg,
            'sort': sorted,
            'page_limit': '$limit',
            'page_start': '$pageStart',
          },
        )
        .toString();

    Future<List<WallSubject>> fetch(String tg) async {
      final res = await _dio.get<String>(
        buildUri(tg),
        options: Options(headers: _headers),
      );
      final Map<String, dynamic> json =
          jsonDecode(res.data ?? '{}') as Map<String, dynamic>;
      final list = (json['subjects'] as List<dynamic>? ?? const <dynamic>[]);
      return list
          .whereType<Map<String, dynamic>>()
          .map(
            (s) => WallSubject(
              id: s['id']?.toString() ?? '',
              title: s['title']?.toString() ?? '',
              rate: s['rate']?.toString() ?? '',
              cover: s['cover']?.toString() ?? '',
              url: s['url']?.toString() ?? '',
            ),
          )
          .where(
            (e) => e.id.isNotEmpty && e.title.isNotEmpty && e.cover.isNotEmpty,
          )
          .toList();
    }

    // 依次尝试候选 tag，首个非空结果即采用（会有网络请求）
    var items = const <WallSubject>[];
    for (final tg in attempts) {
      items = await fetch(tg);
      if (items.isNotEmpty) break;
    }
    _cache[key] = items;
    _cacheAt[key] = DateTime.now();
    return items;
  }

  /// 详情：rexxar 主源 → 失败降级 subject_abstract
  Future<WallDetail> detail(String id, WallSubject fallback) async {
    try {
      final res = await _dio.get<String>(
        '$_doubleRexxar/$id',
        options: Options(
          headers: <String, String>{
            ..._headers,
            'referer': 'https://m.douban.com/movie/subject/$id/',
          },
        ),
      );
      final Map<String, dynamic> r =
          jsonDecode(res.data ?? '{}') as Map<String, dynamic>;
      final pic = (r['pic'] as Map?) ?? const <String, dynamic>{};
      return WallDetail(
        title: r['title']?.toString() ?? fallback.title,
        originalTitle: r['original_title']?.toString() ?? '',
        year: r['year']?.toString() ?? '',
        rate: ((r['rating'] as Map?)?['value'])?.toString() ?? fallback.rate,
        ratingCount: (((r['rating'] as Map?)?['count']) as num?)?.round() ?? 0,
        cover:
            pic['normal']?.toString() ??
            pic['large']?.toString() ??
            fallback.cover,
        url: r['url']?.toString() ?? fallback.url,
        genres: _strList(r['genres']),
        countries: _strList(r['countries']),
        directors: _names(r['directors']),
        actors: _names(r['actors']),
        intro: r['intro']?.toString() ?? '',
        source: 'detail',
      );
    } catch (_) {
      final res = await _dio.get<String>(
        '$_doubanBase/j/subject_abstract?subject_id=$id',
        options: Options(headers: _headers),
      );
      final Map<String, dynamic> root =
          jsonDecode(res.data ?? '{}') as Map<String, dynamic>;
      final s = (root['subject'] as Map?) ?? const <String, dynamic>{};
      return WallDetail(
        title: s['title']?.toString() ?? fallback.title,
        originalTitle: '',
        year: s['release_year']?.toString() ?? '',
        rate: s['rate']?.toString() ?? fallback.rate,
        ratingCount: 0,
        cover: s['cover']?.toString() ?? fallback.cover,
        url: fallback.url,
        genres: _strList(s['types']),
        countries: <String>[?s['region']?.toString()],
        directors: const <String>[],
        actors: const <String>[],
        intro: '',
        source: 'abstract',
      );
    }
  }

  List<String> _strList(Object? v) =>
      (v as List?)
          ?.map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList() ??
      const <String>[];

  List<String> _names(Object? v) =>
      (v as List?)
          ?.map((e) => (e as Map?)?['name']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList() ??
      const <String>[];
}

// ---------------------------------------------------------------- 发现页

const List<String> _movieCategories = <String>[
  '全部',
  '华语',
  '欧美',
  '日本',
  '韩国',
  '动画',
  '喜剧',
  '爱情',
  '科幻',
  '悬疑',
  '恐怖',
  '动作',
  '纪录片',
];
const List<String> _tvCategories = <String>[
  '全部',
  '国产剧',
  '港剧',
  '美剧',
  '英剧',
  '韩剧',
  '日剧',
  '日本动画',
  '综艺',
  '纪录片',
];

/// 发现页「视图来源」：默认海报墙，下拉可切到热搜榜（磁力源榜单）。
typedef DiscoverViewSpec = ({
  String id,
  String label,
  String short,
  bool enabled,
});

/// 【预留扩展】后续接入 TMDB / 自建榜单 / 115 广场等，只需在此追加一项，
/// 并在 `_DiscoverPageState` 的视图分支里补一处即可，无需改已有结构。
const List<DiscoverViewSpec> kDiscoverViews = <DiscoverViewSpec>[
  (id: 'poster', label: '海报墙 · 豆瓣', short: '海报墙', enabled: true),
  (id: 'person', label: '分类 · 人物分类', short: '人物分类', enabled: true),
  (id: 'hot', label: '热搜榜 · 磁力链接', short: '热搜榜', enabled: true),
  (id: 'tmdb', label: 'TMDB 榜单（待接入）', short: 'TMDB', enabled: false),
];

DiscoverViewSpec _viewSpec(String id) {
  for (final v in kDiscoverViews) {
    if (v.id == id) return v;
  }
  return kDiscoverViews.first;
}

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  String _kind = '影视';
  String _sort = '热门';
  String _category = '全部';

  /// 当前视图（默认海报墙）
  String _view = kDiscoverViews.first.id;

  /// 刷新令牌：自增即触发子板块（热搜榜）重新加载
  int _reloadToken = 0;

  /// 人物分类：角色（导演 / 演员）与类别（全部 / 华语 / 欧美 / 日韩）
  PersonRole _personRole = PersonRole.director;
  String _personCategory = kPersonCategories.first;

  /// 刷新令牌：自增即触发人物分类重新取数
  int _personReloadToken = 0;

  /// 海报墙取数服务做成实例成员，使 30 分钟结果缓存真正生效（原先每次 new 等于无缓存）
  final DoubanService _svc = DoubanService();
  List<WallSubject> _items = const <WallSubject>[];
  bool _loading = false;
  String? _error;
  int _pageStart = 0;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _loadMoreError;
  static const int _pageSize = 18;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 跟随「设置 - 网络」热更新代理与超时
  void _syncSvc() {
    final net = ref.read(appSettingsProvider).network;
    _svc.proxy = net.proxy;
    _svc.timeoutMs = net.timeoutMs;
  }

  /// 统一刷新：只刷新当前下拉选中的视图
  Future<void> _refreshCurrentView() async {
    final label = _viewSpec(_view).short;
    if (_view == 'poster') {
      _svc.invalidate();
      _syncSvc();
      await _load();
    } else {
      // 人物分类与热搜榜各自持有独立令牌，刷新一个不动另一个
      setState(() {
        if (_view == 'person') {
          _personReloadToken++;
        } else {
          _reloadToken++;
        }
      });
    }
    if (!mounted) return;
    showHubToast(context, '已刷新「$label」');
  }

  Future<void> _load() async {
    final settings = ref.read(appSettingsProvider);
    if (!settings.recommend.enabled) {
      setState(() {
        _error = 'disabled';
        _loading = false;
      });
      return;
    }
    _syncSvc();
    setState(() {
      _loading = true;
      _error = null;
      _pageStart = 0;
      _hasMore = true;
      _loadMoreError = null;
    });
    try {
      final items = await _svc.wall(
        kind: _kind,
        sort: _sort,
        category: _category,
        limit: _pageSize,
        pageStart: 0,
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _pageStart = items.length;
        _hasMore = items.length >= _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;
    _syncSvc();
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final more = await _svc.wall(
        kind: _kind,
        sort: _sort,
        category: _category,
        limit: _pageSize,
        pageStart: _pageStart,
      );
      if (!mounted) return;
      setState(() {
        _items = <WallSubject>[..._items, ...more];
        _pageStart += more.length;
        _hasMore = more.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadMoreError = '$e';
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final cats = _kind == '剧集' ? _tvCategories : _movieCategories;
    final isPoster = _view == 'poster';
    final isPerson = _view == 'person';

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        // 头部 + 视图切换 + 刷新
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('发现', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '海报墙 / 人物分类 / 热搜榜 · 下拉切换 · 点海报看详情 · 一键去搜索',
                  style: TextStyle(color: t.textDim),
                ),
              ],
            ),
            Wrap(
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                HubDropdown<String>(
                  label: '视图',
                  minWidth: 172,
                  items: kDiscoverViews
                      .map((v) => (v.id, v.label, v.enabled))
                      .toList(),
                  value: _view,
                  onChanged: (v) => setState(() => _view = v),
                ),
                _RefreshButton(
                  busy: isPoster && _loading,
                  label: '刷新${_viewSpec(_view).short}',
                  onTap: _refreshCurrentView,
                ),
              ],
            ),
          ],
        ),
        // 海报墙专属筛选区（切到热搜榜时整体隐藏，避免控件语义串味）
        if (isPoster) ...<Widget>[
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              HubSegmented<String>(
                label: '大类',
                items: const <(String, String)>[('影视', '影视'), ('剧集', '剧集')],
                value: _kind,
                onChanged: (v) {
                  setState(() {
                    _kind = v;
                    _category = '全部';
                  });
                  _load();
                },
              ),
              HubSegmented<String>(
                label: '排序维度',
                items: const <(String, String)>[
                  ('热门', '热门'),
                  ('最新', '最新'),
                  ('豆瓣高分', '高分'),
                ],
                value: _sort,
                onChanged: (v) {
                  setState(() => _sort = v);
                  _load();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: cats.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => HubChip(
                label: cats[i],
                selected: cats[i] == _category,
                onTap: () {
                  setState(() => _category = cats[i]);
                  _load();
                },
              ),
            ),
          ),
          const SizedBox(height: 18),
        ],
        // 人物分类专属筛选区：角色 + 类别（与海报墙互斥，避免控件语义串味）
        if (isPerson) ...<Widget>[
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              HubSegmented<PersonRole>(
                label: '角色',
                items: const <(PersonRole, String)>[
                  (PersonRole.director, '导演'),
                  (PersonRole.actor, '演员'),
                ],
                value: _personRole,
                onChanged: (v) => setState(() => _personRole = v),
              ),
              HubSegmented<String>(
                label: '类别',
                items: kPersonCategories.map((c) => (c, c)).toList(),
                value: _personCategory,
                onChanged: (v) => setState(() => _personCategory = v),
              ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        // 三个视图都保持存活（Offstage），切换零等待且互不触发刷新
        Offstage(offstage: !isPoster, child: _buildWallCard(context, t)),
        if (isPoster) const SizedBox(height: 22),
        Offstage(
          offstage: !isPerson,
          child: PersonBoard(
            role: _personRole,
            category: _personCategory,
            reloadToken: _personReloadToken,
          ),
        ),
        if (isPerson) const SizedBox(height: 22),
        Offstage(
          offstage: isPoster || isPerson,
          child: _HotBoard(reloadToken: _reloadToken),
        ),
      ],
    );
  }

  /// 海报墙独立成卡片：把「加载更多」收进卡片内，避免与下方热搜榜分区混淆
  Widget _buildWallCard(BuildContext context, AppTokens t) {
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Icon(Icons.movie_filter_outlined, color: t.accent, size: 18),
              const SizedBox(width: 2),
              Text('豆瓣海报墙', style: Theme.of(context).textTheme.titleMedium),
              HubChip(label: '$_kind · $_sort · $_category', selected: true),
              if (_items.isNotEmpty) HubChip(label: '已加载 ${_items.length} 张'),
            ],
          ),
          const SizedBox(height: 14),
          _buildBody(context, t),
          const SizedBox(height: 14),
          _buildLoadMore(t),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppTokens t) {
    if (_error == 'disabled') {
      return HubCard(
        dashed: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '首页推荐已关闭',
              style: TextStyle(color: t.warn, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text('可在「设置 - 首页推荐」重新开启。', style: TextStyle(color: t.textDim)),
          ],
        ),
      );
    }
    if (_loading) return _buildSkeleton();
    if (_error != null) {
      // 板块级失败降级：不影响其余板块，提供重试
      return HubCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '海报墙加载失败（板块级降级）',
              style: TextStyle(color: t.danger, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text('失败原因：$_error', style: TextStyle(color: t.textDim)),
            const SizedBox(height: 12),
            AccentButton(
              label: '重试',
              icon: Icons.refresh,
              onPressed: () => _load(),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Text('该分类暂无数据。', style: TextStyle(color: t.textDim));
    }
    final proxy = ref.read(appSettingsProvider).network.proxy;
    return LayoutBuilder(
      builder: (context, c) {
        final cross = c.maxWidth > 1200 ? 8 : (c.maxWidth > 860 ? 6 : 4);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: 2 / 3,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) => PosterCard(
            subject: _items[i],
            proxy: proxy,
            onTap: () => _openDetail(context, _items[i]),
          ),
        );
      },
    );
  }

  Widget _buildLoadMore(AppTokens t) {
    if (!_hasMore) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '海报墙已全部加载（共 ${_items.length} 张）',
            style: TextStyle(color: t.textDim, fontSize: 13),
          ),
        ),
      );
    }
    if (_loadingMore) {
      return const Center(
        child: SkeletonBox(height: 44, radius: 12, width: 200),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: AccentButton(
            label: '加载更多海报',
            icon: Icons.expand_more,
            onPressed: () => _loadMore(),
          ),
        ),
        if (_loadMoreError != null) ...<Widget>[
          const SizedBox(height: 10),
          Center(
            child: Text(
              '加载失败：$_loadMoreError',
              style: TextStyle(color: t.danger, fontSize: 13),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: GhostButton(label: '重试', onPressed: () => _loadMore()),
          ),
        ],
      ],
    );
  }

  Widget _buildSkeleton() {
    return LayoutBuilder(
      builder: (context, c) {
        final cross = c.maxWidth > 1200 ? 8 : (c.maxWidth > 860 ? 6 : 4);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: 2 / 3,
          ),
          itemCount: cross * 2,
          itemBuilder: (_, _) => const SkeletonBox(height: 220, radius: 14),
        );
      },
    );
  }

  void _openDetail(BuildContext context, WallSubject s) {
    showDialog<void>(
      context: context,
      builder: (_) => SubjectDetailDialog(
        subject: s,
        proxy: ref.read(appSettingsProvider).network.proxy,
      ),
    );
  }
}

/// 海报卡：鼠标悬停时「凸起 + 边框高亮 + 投影加深」，并浮出「查看详情」提示
class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.subject,
    required this.proxy,
    required this.onTap,
  });
  final WallSubject subject;
  final String proxy;
  final VoidCallback onTap;

  @override
  State<PosterCard> createState() => PosterCardState();
}

class PosterCardState extends State<PosterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _hovered ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 170),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _hovered ? t.accent : Colors.transparent,
                  width: 2,
                ),
                boxShadow: _hovered
                    ? <BoxShadow>[
                        BoxShadow(
                          color: t.accent.withValues(alpha: 0.34),
                          blurRadius: 22,
                          spreadRadius: 1,
                          offset: const Offset(0, 7),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.34),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ]
                    : <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    RefererImage(
                      url: widget.subject.cover,
                      referer: kDoubanReferer,
                      proxy: widget.proxy,
                      fit: BoxFit.cover,
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              Colors.transparent,
                              Color(0xCC000000),
                            ],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              widget.subject.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              ),
                            ),
                            if (widget.subject.rate.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  '★ ${widget.subject.rate}',
                                  style: TextStyle(
                                    color: t.warn,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    // 悬停蒙层：明确可点，避免「海报看着像图片」的误判
                    AnimatedOpacity(
                      opacity: _hovered ? 1 : 0,
                      duration: const Duration(milliseconds: 170),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.22),
                        ),
                        alignment: Alignment.center,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: t.accent,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: t.accent.withValues(alpha: 0.45),
                                blurRadius: 14,
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.info_outline,
                                size: 14,
                                color: Colors.white,
                              ),
                              SizedBox(width: 5),
                              Text(
                                '查看详情',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SubjectDetailDialog extends StatelessWidget {
  const SubjectDetailDialog({
    super.key,
    required this.subject,
    required this.proxy,
  });
  final WallSubject subject;
  final String proxy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Dialog(
      backgroundColor: t.surface1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: t.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: FutureBuilder<WallDetail>(
            future: DoubanService(proxy: proxy).detail(subject.id, subject),
            builder: (context, snap) {
              if (snap.hasError) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      subject.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '详情加载失败：${snap.error}',
                      style: TextStyle(color: t.danger),
                    ),
                  ],
                );
              }
              if (!snap.hasData) {
                return const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final d = snap.data!;
              return SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(
                      width: 130,
                      height: 195,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: RefererImage(
                          url: d.cover,
                          referer: kDoubanReferer,
                          proxy: proxy,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            d.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '★ ${d.rate} · ${d.year} · ${d.countries.join('/')}',
                            style: TextStyle(
                              color: t.warn,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _kv(context, '导演', d.directors.join(' / ')),
                          _kv(context, '主演', d.actors.take(6).join(' / ')),
                          _kv(context, '类型', d.genres.join(' / ')),
                          if (d.intro.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 10),
                            Text(
                              '简介',
                              style: TextStyle(color: t.textDim, fontSize: 13),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              d.intro,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: t.text, fontSize: 14),
                            ),
                          ],
                          const SizedBox(height: 14),
                          AccentButton(
                            label: '去搜索',
                            icon: Icons.search,
                            onPressed: () {
                              Navigator.of(context).pop();
                              // B1：**先用展示名（中文）检索**，无结果再由搜索页回退到原名。
                              // V1.x 直接拿 originalTitle（英文）去搜，中文用户常常 0 结果。
                              goToSearch(
                                context,
                                SearchSeed(
                                  d.title,
                                  fallback: d.originalTitle.isEmpty
                                      ? null
                                      : d.originalTitle,
                                ),
                              );
                            },
                          ),
                          if (d.source == 'abstract')
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '（详情来自降级接口 subject_abstract）',
                                style: TextStyle(
                                  color: t.textDim,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    if (v.isEmpty) return const SizedBox.shrink();
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          children: <TextSpan>[
            TextSpan(
              text: '$k：',
              style: TextStyle(color: t.textDim, fontSize: 14),
            ),
            TextSpan(
              text: v,
              style: TextStyle(color: t.text, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// 热搜榜：海报墙下方，取「已启用公共磁力源」的热榜，按 hotness 取前 12。
/// 板块级降级：单个源失败不拖垮整页，仅在该板块显示错误 + 重试。
class _HotEntry {
  const _HotEntry(this.item, this.sourceName);
  final ResourceItem item;
  final String sourceName;
}

class _HotBoard extends ConsumerStatefulWidget {
  const _HotBoard({required this.reloadToken});

  /// 父层「刷新」自增此令牌触发重载；保持不变时不会重复请求
  final int reloadToken;

  @override
  ConsumerState<_HotBoard> createState() => _HotBoardState();
}

class _HotBoardState extends ConsumerState<_HotBoard> {
  static const int _collapsedCount = 8;

  List<_HotEntry> _all = const <_HotEntry>[];
  bool _loading = true;
  String? _error;
  bool _expanded = false;

  /// 已启用的真实公共磁力源数量（用于空态提示）
  int _realSourceCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant _HotBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) _load();
  }

  /// 热搜榜只聚合「已启用的真实磁力源」；演示源一律排除，避免虚假条目上屏。
  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) {
      if (!mounted) return;
      setState(() {
        _error = '数据库未就绪';
        _loading = false;
      });
      return;
    }
    final proxy = ref.read(appSettingsProvider).network.proxy;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sources = SourceRepo(db)
          .listAll()
          .where((s) => s.enabled && s.kind == ResourceKind.magnet && !s.demo)
          .toList();
      final pool = <_HotEntry>[];
      final seen = <String>{};
      // 板块级降级：单源失败仅跳过，不影响其余源与其余板块
      for (final s in sources) {
        try {
          final adapter = adapterFor(s);
          final hot = await adapter.fetchHot(
            'hot',
            AdapterContext(source: s, proxy: proxy),
          );
          if (hot == null || hot.isEmpty) continue;
          for (final raw in hot) {
            final item = normalize(raw, s);
            final key = item.dedupeKey.isEmpty ? item.title : item.dedupeKey;
            if (!seen.add(key)) continue;
            pool.add(_HotEntry(item, s.name));
          }
        } catch (_) {
          // 忽略单个源失败，继续下一个源
        }
      }
      pool.sort((a, b) => b.item.hotness.compareTo(a.item.hotness));
      if (!mounted) return;
      setState(() {
        _all = pool;
        _realSourceCount = sources.length;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Icon(Icons.whatshot, color: t.accent, size: 18),
              const SizedBox(width: 2),
              Text('热搜榜', style: Theme.of(context).textTheme.titleMedium),
              HubChip(label: '真实磁力源 $_realSourceCount 个', selected: true),
              if (_all.isNotEmpty)
                HubChip(label: '共 ${_all.length} 条', selected: _all.isNotEmpty),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '数据来自已启用的公共磁力索引实时榜单（演示源已排除）',
            style: TextStyle(color: t.textDim, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          _buildContent(t),
        ],
      ),
    );
  }

  Widget _buildContent(AppTokens t) {
    if (_loading) {
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 2.6,
        ),
        itemCount: 8,
        itemBuilder: (_, _) => const SkeletonBox(height: 88, radius: 14),
      );
    }
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '热搜榜加载失败（板块级降级）',
            style: TextStyle(color: t.danger, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text('失败原因：$_error', style: TextStyle(color: t.textDim)),
          const SizedBox(height: 12),
          GhostButton(label: '重试', onPressed: () => _load()),
        ],
      );
    }
    if (_realSourceCount == 0) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: t.bg1,
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '未启用公共磁力源，热搜榜暂无数据。',
              style: TextStyle(color: t.textHi, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '请在「设置 - 源适配器」启用真实磁力源后重试。',
              style: TextStyle(color: t.textDim, fontSize: 12.5),
            ),
          ],
        ),
      );
    }
    if (_all.isEmpty) {
      return Text(
        '热搜榜暂时取不到数据（源可达但榜单为空），可稍后重试。',
        style: TextStyle(color: t.textDim),
      );
    }

    final shown = _expanded ? _all : _all.take(_collapsedCount).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth > 1200 ? 4 : (c.maxWidth > 820 ? 3 : 2);
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 2.6,
              ),
              itemCount: shown.length,
              itemBuilder: (context, i) => _HotTile(
                rank: i + 1,
                entry: shown[i],
                onTap: () =>
                    goToSearch(context, SearchSeed(shown[i].item.title)),
              ),
            );
          },
        ),
        if (_all.length > _collapsedCount) ...<Widget>[
          const SizedBox(height: 12),
          Center(
            child: GhostButton(
              label: _expanded ? '收起' : '展开全部 ${_all.length} 条',
              icon: _expanded ? Icons.expand_less : Icons.expand_more,
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
        ],
      ],
    );
  }
}

class _HotTile extends StatelessWidget {
  const _HotTile({
    required this.rank,
    required this.entry,
    required this.onTap,
  });
  final int rank;
  final _HotEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final top = rank <= 3;
    return HubCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: top ? t.accent : t.bg1,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: top ? t.accent : t.border),
            ),
            child: Text(
              '$rank',
              style: TextStyle(
                color: top ? Colors.white : t.textDim,
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  entry.item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.textHi,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${entry.sourceName} · 热度 ${entry.item.hotness.toStringAsFixed(0)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.textDim, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 统一刷新按钮：只刷新「当前视图」；加载中自转圈并禁用，避免连点打爆接口
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({
    required this.busy,
    required this.label,
    required this.onTap,
  });

  final bool busy;
  final String label;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Tooltip(
      message: '刷新当前视图的数据（不影响另一视图）',
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: t.surface1,
          border: Border.all(color: busy ? t.accent : t.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: busy ? null : () => onTap(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (busy)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: t.accent,
                    ),
                  )
                else
                  Icon(Icons.refresh, size: 16, color: t.accent),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 跳转搜索页并注入关键词（通过全局 NavIndex + 搜索页监听）
///
/// 具体实现见 `features/search/search_seed.dart`（含 B1 的「展示名优先、原名回退」语义）。
