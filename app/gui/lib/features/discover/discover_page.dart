import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/image_loader.dart';
import '../../features/search/search_engine.dart';
import '../../sources/adapters.dart';
import '../../sources/source.dart';
import '../../state/providers.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

const String _doubanBase = 'https://movie.douban.com';
const String _doubleRexxar = 'https://m.douban.com/rexxar/api/v2/movie';
const String _doubanReferer = 'https://movie.douban.com/';
const String _doubanUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

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
  DoubanService({String proxy = '', int timeoutMs = 8000})
      : _proxy = proxy,
        _timeout = timeoutMs;

  final String _proxy;
  final int _timeout;

  final Map<String, List<WallSubject>> _cache = <String, List<WallSubject>>{};
  final Map<String, DateTime> _cacheAt = <String, DateTime>{};

  Dio get _dio {
    final d = Dio(BaseOptions(
      connectTimeout: Duration(milliseconds: _timeout),
      receiveTimeout: Duration(milliseconds: _timeout),
      responseType: ResponseType.plain,
    ));
    if (_proxy.isNotEmpty) {
      d.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final c = HttpClient();
        c.findProxy = (uri) => 'PROXY $_proxy';
        return c;
      });
    }
    return d;
  }

  Map<String, String> get _headers => <String, String>{
        'user-agent': _doubanUa,
        'referer': _doubanReferer,
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
    // 选中细分时用分类作 tag；否则用维度本身
    final tag = (category == '全部') ? sort : category;

    final key = '$kind|$sorted|$tag|$limit|$pageStart';
    final cachedAt = _cacheAt[key];
    if (cachedAt != null &&
        DateTime.now().difference(cachedAt).inMinutes < 30 &&
        _cache.containsKey(key)) {
      return _cache[key]!;
    }


    String buildUri(String tg) => Uri.parse('$_doubanBase/j/search_subjects').replace(
          queryParameters: <String, String>{
            'type': type,
            'tag': tg,
            'sort': sorted,
            'page_limit': '$limit',
            'page_start': '$pageStart',
          },
        ).toString();

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
          .map((s) => WallSubject(
                id: s['id']?.toString() ?? '',
                title: s['title']?.toString() ?? '',
                rate: s['rate']?.toString() ?? '',
                cover: s['cover']?.toString() ?? '',
                url: s['url']?.toString() ?? '',
              ))
          .where((e) => e.id.isNotEmpty && e.title.isNotEmpty && e.cover.isNotEmpty)
          .toList();
    }

    var items = await fetch(tag);
    // 细分×维度返回 0 条 → 回退为仅按维度再取一次
    if (items.isEmpty && category != '全部') {
      items = await fetch(sort);
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
        options: Options(headers: <String, String>{
          ..._headers,
          'referer': 'https://m.douban.com/movie/subject/$id/',
        }),
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
        cover: pic['normal']?.toString() ?? pic['large']?.toString() ?? fallback.cover,
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

  List<String> _strList(Object? v) => (v as List?)
          ?.map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList() ??
      const <String>[];

  List<String> _names(Object? v) => (v as List?)
          ?.map((e) => (e as Map?)?['name']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList() ??
      const <String>[];
}

// ---------------------------------------------------------------- 发现页

const List<String> _movieCategories = <String>[
  '全部', '华语', '欧美', '日本', '韩国', '动画', '喜剧', '爱情', '科幻', '悬疑', '恐怖', '动作', '纪录片'
];
const List<String> _tvCategories = <String>[
  '全部', '国产剧', '港剧', '美剧', '英剧', '韩剧', '日剧', '日本动画', '综艺', '纪录片'
];

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends ConsumerState<DiscoverPage> {
  String _kind = '影视';
  String _sort = '热门';
  String _category = '全部';
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

  Future<void> _load({bool force = false}) async {
    final settings = ref.read(appSettingsProvider);
    if (!settings.recommend.enabled) {
      setState(() {
        _error = 'disabled';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _pageStart = 0;
      _hasMore = true;
      _loadMoreError = null;
    });
    try {
      final svc = DoubanService(
        proxy: settings.network.proxy,
        timeoutMs: settings.network.timeoutMs,
      );
      final items = await svc.wall(
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
    final settings = ref.read(appSettingsProvider);
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final svc = DoubanService(
        proxy: settings.network.proxy,
        timeoutMs: settings.network.timeoutMs,
      );
      final more = await svc.wall(
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        // 头部 + 维度切换
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
                Text('豆瓣海报墙 · 点海报看详情 · 一键去搜索',
                    style: TextStyle(color: t.textDim)),
              ],
            ),
            Wrap(
              spacing: 10,
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
                    ('豆瓣高分', '高分')
                  ],
                  value: _sort,
                  onChanged: (v) {
                    setState(() => _sort = v);
                    _load();
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        // 细分分类
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cats.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
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
        _buildBody(context, t),
        const SizedBox(height: 28),
        _HotBoard(),
      ],
    );
  }

  Widget _buildBody(BuildContext context, AppTokens t) {
    if (_error == 'disabled') {
      return HubCard(
        dashed: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('首页推荐已关闭', style: TextStyle(color: t.warn, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('可在「设置 - 推荐」重新开启。', style: TextStyle(color: t.textDim)),
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
            Text('海报墙加载失败（板块级降级）',
                style: TextStyle(color: t.danger, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('失败原因：$_error', style: TextStyle(color: t.textDim)),
            const SizedBox(height: 12),
            AccentButton(label: '重试', icon: Icons.refresh, onPressed: () => _load()),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return HubCard(
        child: Text('该分类暂无数据。', style: TextStyle(color: t.textDim)),
      );
    }
    final proxy = ref.read(appSettingsProvider).network.proxy;
    return LayoutBuilder(builder: (context, c) {
      final cross = c.maxWidth > 1200 ? 8 : (c.maxWidth > 860 ? 6 : 4);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cross,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
              childAspectRatio: 2 / 3,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) => _PosterCard(
              subject: _items[i],
              proxy: proxy,
              onTap: () => _openDetail(context, _items[i]),
            ),
          ),
          const SizedBox(height: 16),
          _buildLoadMore(t),
        ],
      );
    });
  }

  Widget _buildLoadMore(AppTokens t) {
    if (!_hasMore) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text('没有更多了', style: TextStyle(color: t.textDim, fontSize: 13)),
        ),
      );
    }
    if (_loadingMore) {
      return const Center(child: SkeletonBox(height: 44, radius: 12, width: 200));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
            child: AccentButton(
            label: '加载更多',
            icon: Icons.expand_more,
            onPressed: () => _loadMore(),
          ),
        ),
        if (_loadMoreError != null) ...<Widget>[
          const SizedBox(height: 10),
          Center(
            child: Text('加载失败：$_loadMoreError',
                style: TextStyle(color: t.danger, fontSize: 13)),
          ),
          const SizedBox(height: 8),
          Center(child: GhostButton(label: '重试', onPressed: () => _loadMore())),
        ],
      ],
    );
  }

  Widget _buildSkeleton() {
    return LayoutBuilder(builder: (context, c) {
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
        itemBuilder: (_, __) => const SkeletonBox(height: 220, radius: 14),
      );
    });
  }

  void _openDetail(BuildContext context, WallSubject s) {
    showDialog<void>(
      context: context,
      builder: (_) => _DetailDialog(subject: s, proxy: ref.read(appSettingsProvider).network.proxy),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard(
      {required this.subject, required this.proxy, required this.onTap});
  final WallSubject subject;
  final String proxy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Focus(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: RefererImage(
                  url: subject.cover,
                  referer: _doubanReferer,
                  proxy: proxy,
                  fit: BoxFit.cover,
                ),
              ),
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
                    colors: <Color>[Colors.transparent, Color(0xCC000000)],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      subject.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5),
                    ),
                    if (subject.rate.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('★ ${subject.rate}',
                            style: TextStyle(
                                color: t.warn,
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailDialog extends StatelessWidget {
  const _DetailDialog({required this.subject, required this.proxy});
  final WallSubject subject;
  final String proxy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Dialog(
      backgroundColor: t.surfaceSolid,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: t.border)),
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
                    Text(subject.title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Text('详情加载失败：${snap.error}', style: TextStyle(color: t.danger)),
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
                          referer: _doubanReferer,
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
                          Text(d.title, style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 6),
                          Text(
                            '★ ${d.rate} · ${d.year} · ${d.countries.join('/')}',
                            style: TextStyle(
                                color: t.warn, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 10),
                          _kv(context, '导演', d.directors.join(' / ')),
                          _kv(context, '主演', d.actors.take(6).join(' / ')),
                          _kv(context, '类型', d.genres.join(' / ')),
                          if (d.intro.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 10),
                            Text('简介', style: TextStyle(color: t.textDim, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text(d.intro,
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: t.text, fontSize: 14)),
                          ],
                          const SizedBox(height: 14),
                          AccentButton(
                            label: '去搜索',
                            icon: Icons.search,
                            onPressed: () {
                              Navigator.of(context).pop();
                              // 跳转到搜索页并带入关键词
                              goToSearch(context, d.originalTitle.isNotEmpty
                                  ? d.originalTitle
                                  : d.title);
                            },
                          ),
                          if (d.source == 'abstract')
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '（详情来自降级接口 subject_abstract）',
                                style: TextStyle(color: t.textDim, fontSize: 12),
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
        text: TextSpan(children: <TextSpan>[
          TextSpan(text: '$k：', style: TextStyle(color: t.textDim, fontSize: 14)),
          TextSpan(text: v, style: TextStyle(color: t.text, fontSize: 14)),
        ]),
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
  const _HotBoard();

  @override
  ConsumerState<_HotBoard> createState() => _HotBoardState();
}

class _HotBoardState extends ConsumerState<_HotBoard> {
  List<_HotEntry> _items = const <_HotEntry>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

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
          .where((s) => s.enabled && s.kind == ResourceKind.magnet)
          .toList();
      final pool = <_HotEntry>[];
      // 板块级降级：单源失败仅跳过，不影响整页其余部分
      for (final s in sources) {
        try {
          final adapter = adapterFor(s);
          final hot = await adapter.fetchHot(
            'hot',
            AdapterContext(source: s, proxy: proxy),
          );
          if (hot == null || hot.isEmpty) continue;
          for (final raw in hot) {
            pool.add(_HotEntry(normalize(raw, s), s.name));
          }
        } catch (_) {
          // 忽略单个源失败，继续下一个源
        }
      }
      pool.sort((a, b) => b.item.hotness.compareTo(a.item.hotness));
      if (!mounted) return;
      setState(() {
        _items = pool.take(12).toList();
        _loading = false;
        _error = _items.isEmpty ? '暂无热搜数据' : null;
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
          Row(
            children: <Widget>[
              Icon(Icons.whatshot, color: t.accent, size: 18),
              const SizedBox(width: 8),
              Text('热搜榜', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              HubChip(label: '已启用磁力源', selected: true),
            ],
          ),
          const SizedBox(height: 14),
          _buildContent(t),
        ],
      ),
    );
  }

  Widget _buildContent(AppTokens t) {
    if (_loading) {
      return SizedBox(
        height: 150,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: 6,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, __) => const SizedBox(
            width: 200,
            child: SkeletonBox(height: 150, radius: 14),
          ),
        ),
      );
    }
    if (_error != null) {
      // 板块级失败降级：不影响其余板块，提供重试
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('热搜榜加载失败（板块级降级）',
              style: TextStyle(color: t.danger, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('失败原因：$_error', style: TextStyle(color: t.textDim)),
          const SizedBox(height: 12),
          GhostButton(label: '重试', onPressed: () => _load()),
        ],
      );
    }
    if (_items.isEmpty) {
      return Text('暂无热搜数据。', style: TextStyle(color: t.textDim));
    }
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final e = _items[i];
          return SizedBox(
            width: 200,
            child: HubCard(
              padding: const EdgeInsets.all(14),
              onTap: () => goToSearch(context, e.item.title),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      e.item.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.textHi,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Icon(Icons.whatshot, color: t.warn, size: 13),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          e.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.textDim, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 跳转搜索页并注入关键词（通过全局 NavIndex + 搜索页监听）
final ValueNotifier<String?> searchSeedNotifier = ValueNotifier<String?>(null);

void goToSearch(BuildContext context, String keyword) {
  searchSeedNotifier.value = keyword;
  ProviderScope.containerOf(context).read(navIndexProvider.notifier).select(2);
}
