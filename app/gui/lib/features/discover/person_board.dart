import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/image_loader.dart';
import '../../state/providers.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'discover_page.dart'
    show
        kDoubanReferer,
        kDoubanUa,
        newDoubanDio,
        PosterCard,
        SubjectDetailDialog,
        WallSubject;
import 'person_catalog.dart';

const String _rexxarCelebrity = 'https://m.douban.com/rexxar/api/v2/celebrity';

/// 单个人物的「资料 + 代表作」结果
typedef PersonSnapshot = ({PersonProfile profile, List<PersonWork> works});

/// 豆瓣人物取数（Dio 口径与 `DoubanService` 完全一致：同代理 / 同超时 / 同 UA）
///
/// - 解析 id：GET movie.douban.com/j/subject_suggest?q=<人物名>
/// - 人物资料：GET m.douban.com/rexxar/api/v2/celebrity/<旧 celebrity id>
/// - 代表作：  GET .../celebrity/<旧 celebrity id>/works?start=0&count=50
///
/// 注意：works 只认 **suggest 返回的旧 celebrity id**；
/// 资料接口里的新 personage id（如诺兰的 27260291）请求 works 会 404。
class DoubanPersonService {
  DoubanPersonService({this.proxy = '', this.timeoutMs = 8000});

  /// 可热更新（跟随「设置 - 网络」变化）
  String proxy;
  int timeoutMs;

  final Map<String, PersonSuggest> _suggestCache = <String, PersonSuggest>{};
  final Map<String, PersonProfile> _profileCache = <String, PersonProfile>{};
  final Map<String, List<PersonWork>> _worksCache =
      <String, List<PersonWork>>{};

  /// 手动刷新入口：清空全部缓存
  void invalidate() {
    _suggestCache.clear();
    _profileCache.clear();
    _worksCache.clear();
  }

  Dio get _dio => newDoubanDio(proxy: proxy, timeoutMs: timeoutMs);

  Map<String, String> get _headers => <String, String>{
    'user-agent': kDoubanUa,
    'referer': kDoubanReferer,
    'accept': 'application/json, text/plain, */*',
    'accept-language': 'zh-CN,zh;q=0.9',
  };

  Map<String, String> _headersFor(String celebrityId) => <String, String>{
    ..._headers,
    'referer': 'https://m.douban.com/movie/celebrity/$celebrityId/',
  };

  Future<Object?> _getJson(String url, Map<String, String> headers) async {
    final res = await _dio.get<String>(url, options: Options(headers: headers));
    final body = res.data;
    if (body == null || body.isEmpty) return null;
    return jsonDecode(body);
  }

  /// 人物名 → 豆瓣 celebrity；没命中抛 [PersonResolveException]（提示语直接给用户）
  Future<PersonSuggest> suggestPerson(String name) async {
    final cached = _suggestCache[name];
    if (cached != null) return cached;
    final uri = Uri.parse('https://movie.douban.com/j/subject_suggest')
        .replace(queryParameters: <String, String>{'q': name})
        .toString();
    final json = await _getJson(uri, _headers);
    final hit = parseCelebritySuggest(json);
    if (hit == null) {
      throw PersonResolveException('未找到「$name」对应的人物条目');
    }
    _suggestCache[name] = hit;
    return hit;
  }

  /// 人物资料；失败时退化为 suggest 已有的名字 / 头像，不阻断代表作展示
  Future<PersonProfile> profile(
    String celebrityId,
    PersonSuggest suggest,
  ) async {
    final cached = _profileCache[celebrityId];
    if (cached != null) return cached;
    PersonProfile p;
    try {
      final json = await _getJson(
        '$_rexxarCelebrity/$celebrityId',
        _headersFor(celebrityId),
      );
      p = parseCelebrityProfile(
        json,
        fallbackName: suggest.name,
        fallbackAvatar: suggest.avatar,
        fallbackLatinName: suggest.subTitle,
      );
    } catch (_) {
      // 板块级降级：资料接口失败时仍保留名字、外文名与头像
      p = parseCelebrityProfile(
        null,
        fallbackName: suggest.name,
        fallbackAvatar: suggest.avatar,
        fallbackLatinName: suggest.subTitle,
      );
    }
    _profileCache[celebrityId] = p;
    return p;
  }

  /// 代表作：按角色过滤 + 评分降序 + 去重（见 `parseCelebrityWorks`）
  Future<List<PersonWork>> works(
    String celebrityId, {
    required PersonRole role,
    int limit = 12,
  }) async {
    final key = '$celebrityId|${role.name}|$limit';
    final cached = _worksCache[key];
    if (cached != null) return cached;
    final json = await _getJson(
      '$_rexxarCelebrity/$celebrityId/works?start=0&count=50',
      _headersFor(celebrityId),
    );
    final list = parseCelebrityWorks(json, role: role, limit: limit);
    _worksCache[key] = list;
    return list;
  }
}

/// 人物解析失败（suggest 未命中 celebrity）
class PersonResolveException implements Exception {
  const PersonResolveException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 发现页「人物分类」板块：人物标签 → 人物资料 + 代表作
///
/// - 角色 / 类别由父层（发现页筛选区）下发，本板块只负责渲染与取数
/// - [PersonBoard.reloadToken] 自增触发重新取数（父层「刷新」按钮）
class PersonBoard extends ConsumerStatefulWidget {
  const PersonBoard({
    super.key,
    required this.role,
    required this.category,
    required this.reloadToken,
  });

  final PersonRole role;
  final String category;
  final int reloadToken;

  @override
  ConsumerState<PersonBoard> createState() => _PersonBoardState();
}

class _PersonBoardState extends ConsumerState<PersonBoard> {
  final DoubanPersonService _svc = DoubanPersonService();

  PersonEntry? _selected;
  bool _loading = false;
  String? _error;
  PersonSnapshot? _snapshot;

  /// 取数序号：丢弃过期响应，避免连点导致结果错位
  int _seq = 0;

  List<PersonEntry> get _catalog =>
      personCatalogOf(role: widget.role, category: widget.category);

  @override
  void didUpdateWidget(covariant PersonBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) {
      _svc.invalidate();
      final sel = _selected;
      if (sel != null) {
        _loadPerson(sel);
      } else {
        setState(() => _error = null);
      }
      return;
    }
    final sel = _selected;
    if (sel == null) return;
    if (oldWidget.role != widget.role) {
      // 同一人物换角色维度：仍在目录里就只重取代表作，否则清空
      if (sel.roles.contains(widget.role)) {
        _loadPerson(sel);
      } else {
        _clearSelection();
      }
      return;
    }
    if (oldWidget.category != widget.category &&
        widget.category != '全部' &&
        sel.category != widget.category) {
      _clearSelection();
    }
  }

  /// 跟随「设置 - 网络」热更新代理与超时
  void _syncSvc() {
    final net = ref.read(appSettingsProvider).network;
    _svc.proxy = net.proxy;
    _svc.timeoutMs = net.timeoutMs;
  }

  void _clearSelection() {
    _seq++;
    setState(() {
      _selected = null;
      _snapshot = null;
      _error = null;
      _loading = false;
    });
  }

  Future<void> _loadPerson(PersonEntry entry) async {
    _syncSvc();
    final seq = ++_seq;
    setState(() {
      _selected = entry;
      _loading = true;
      _error = null;
      _snapshot = null;
    });
    try {
      final suggest = await _svc.suggestPerson(entry.name);
      final results = await Future.wait<Object>(<Future<Object>>[
        _svc.profile(suggest.id, suggest),
        _svc.works(suggest.id, role: widget.role),
      ]);
      if (!mounted || seq != _seq) return;
      setState(() {
        _snapshot = (
          profile: results[0] as PersonProfile,
          works: results[1] as List<PersonWork>,
        );
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final catalog = _catalog;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Icon(Icons.person_outline, color: t.accent, size: 18),
              const SizedBox(width: 2),
              Text('人物分类', style: Theme.of(context).textTheme.titleMedium),
              HubChip(
                label: '${widget.role.label} · ${widget.category}',
                selected: true,
              ),
              HubChip(label: '${catalog.length} 人'),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '点人物看资料与其${widget.role.worksTitle}；海报可点开看详情或去搜索',
            style: TextStyle(color: t.textDim, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          _buildTags(t, catalog),
          const SizedBox(height: 16),
          _buildResult(t),
        ],
      ),
    );
  }

  Widget _buildTags(AppTokens t, List<PersonEntry> catalog) {
    if (catalog.isEmpty) {
      return Text('该分类暂无人物。', style: TextStyle(color: t.textDim));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: catalog
          .map(
            (p) => HubChip(
              label: p.name,
              selected: p.name == _selected?.name,
              onTap: () => _loadPerson(p),
            ),
          )
          .toList(),
    );
  }

  Widget _buildResult(AppTokens t) {
    if (_selected == null) {
      return Text(
        '选择一位${widget.role.label}查看资料与代表作。',
        style: TextStyle(color: t.textDim),
      );
    }
    if (_loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              SkeletonBox(width: 84, height: 118, radius: 12),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SkeletonBox(width: 160, height: 18),
                    SizedBox(height: 8),
                    SkeletonBox(width: 220, height: 14),
                    SizedBox(height: 8),
                    SkeletonBox(width: 180, height: 14),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _worksSkeleton(),
        ],
      );
    }
    if (_error != null) {
      return HubCard(
        dashed: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '「${_selected!.name}」加载失败（板块级降级）',
              style: TextStyle(color: t.danger, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text('失败原因：$_error', style: TextStyle(color: t.textDim)),
            const SizedBox(height: 12),
            GhostButton(
              label: '重试',
              icon: Icons.refresh,
              onPressed: () => _loadPerson(_selected!),
            ),
          ],
        ),
      );
    }
    final snap = _snapshot;
    if (snap == null) {
      return Text('暂无数据。', style: TextStyle(color: t.textDim));
    }
    final proxy = ref.read(appSettingsProvider).network.proxy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _PersonProfileView(profile: snap.profile, proxy: proxy),
        const SizedBox(height: 16),
        Text(
          widget.role.worksTitle,
          style: TextStyle(
            color: t.textHi,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        if (snap.works.isEmpty)
          Text('没有取到符合条件的代表作（该维度下作品可能过少）。', style: TextStyle(color: t.textDim))
        else
          _WorkGrid(works: snap.works, proxy: proxy, onOpen: _openDetail),
      ],
    );
  }

  Widget _worksSkeleton() {
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
          itemCount: cross,
          itemBuilder: (_, _) => const SkeletonBox(height: 220, radius: 14),
        );
      },
    );
  }

  void _openDetail(WallSubject subject) {
    showDialog<void>(
      context: context,
      builder: (_) => SubjectDetailDialog(
        subject: subject,
        proxy: ref.read(appSettingsProvider).network.proxy,
      ),
    );
  }
}

/// 人物资料：头像 + 名字 + 外文名 + 一句话简介 + 结构化信息
class _PersonProfileView extends StatelessWidget {
  const _PersonProfileView({required this.profile, required this.proxy});

  final PersonProfile profile;
  final String proxy;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 84,
          height: 118,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: RefererImage(
              url: profile.avatar,
              referer: kDoubanReferer,
              proxy: proxy,
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                profile.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (profile.latinName.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  profile.latinName,
                  style: TextStyle(color: t.textDim, fontSize: 13),
                ),
              ],
              if (profile.summary.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  profile.summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text, fontSize: 13.5),
                ),
              ],
              if (profile.facts.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: profile.facts
                      .take(6)
                      .map((f) => HubChip(label: '${f.$1}：${f.$2}'))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 代表作海报墙：复用发现页的 [PosterCard]（悬停凸起 / 详情弹窗 / 去搜索链路一致）
class _WorkGrid extends StatelessWidget {
  const _WorkGrid({
    required this.works,
    required this.proxy,
    required this.onOpen,
  });

  final List<PersonWork> works;
  final String proxy;
  final ValueChanged<WallSubject> onOpen;

  @override
  Widget build(BuildContext context) {
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
          itemCount: works.length,
          itemBuilder: (context, i) {
            final w = works[i];
            final subject = WallSubject(
              id: w.id,
              title: w.title,
              rate: w.rate,
              cover: w.cover,
              url: w.url,
            );
            return PosterCard(
              subject: subject,
              proxy: proxy,
              onTap: () => onOpen(subject),
            );
          },
        );
      },
    );
  }
}
