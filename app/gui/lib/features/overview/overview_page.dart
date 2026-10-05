import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repos.dart';
import '../../core/network/pan115_cloud.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../sources/source.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class OverviewPage extends ConsumerStatefulWidget {
  const OverviewPage({super.key});

  @override
  ConsumerState<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends ConsumerState<OverviewPage> {
  Timer? _timer;

  /// 本地任务快照（含真实进度回填后的结果）
  List<Map<String, Object?>> _rows = const <Map<String, Object?>>[];
  Map<String, int> _stats = const <String, int>{
    'pending': 0,
    'running': 0,
    'success': 0,
    'failed': 0,
  };

  /// 云端同步的最近一次结论（成功条数 / 失败原因），用于在看板头部如实告知
  String _cloudNote = '';
  bool _cloudBusy = false;

  /// 看板「隐藏详情」开关：只作用于本页面会话，切走再回来恢复默认展开。
  /// 隐藏时保留四项统计与同步状态，只收起任务实例行与条数提示。
  bool _hideTaskDetails = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pull();
      _restartTimer();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 轮询节奏跟随「设置 - 115 会话」；关掉开关即停止，不打扰 115 接口
  void _restartTimer() {
    _timer?.cancel();
    final cfg = ref.read(appSettingsProvider).pan115;
    if (!cfg.pollCloudProgress) return;
    _timer = Timer.periodic(
      Duration(seconds: cfg.pollIntervalSeconds),
      (_) => _pull(),
    );
  }

  /// 读本地任务 + 拉一次 115 云端任务列表，把**真实进度**回填到看板（W3）
  Future<void> _pull() async {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null || !mounted) return;
    final repo = ImportRepo(db);

    final settings = ref.read(appSettingsProvider);
    final cfg = settings.pan115;
    final session = ref.read(sessionProvider);

    if (cfg.pollCloudProgress && session.isLoggedIn && !_cloudBusy) {
      _cloudBusy = true;
      try {
        final note = await syncCloudToRepo(
          repo,
          cookie: session.cookie,
          proxy: settings.network.proxy,
          timeoutMs: settings.network.timeoutMs,
        );
        if (mounted) _cloudNote = note;
      } finally {
        _cloudBusy = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _rows = repo.list();
      _stats = repo.stats();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    ref.listen(appSettingsProvider, (prev, next) {
      if (prev?.pan115.pollCloudProgress != next.pan115.pollCloudProgress ||
          prev?.pan115.pollIntervalSeconds != next.pan115.pollIntervalSeconds) {
        _restartTimer();
      }
    });

    final db = ref.watch(appDatabaseProvider).maybeValue;
    final session = ref.watch(sessionProvider);

    final favCount = db == null ? 0 : FavoritesRepo(db).count();
    final stats = db == null
        ? const <String, int>{
            'pending': 0,
            'running': 0,
            'success': 0,
            'failed': 0,
          }
        : _stats;
    final sources = db == null ? <SourceLite>[] : SourceRepo(db).listAll();
    final healthy = sources.where((s) => s.enabled).length;
    final hour = DateTime.now().hour;
    final greet = hour < 6
        ? '凌晨好'
        : (hour < 12 ? '早上好' : (hour < 18 ? '下午好' : '晚上好'));

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        // 英雄区（记忆点：极光脉动）
        HubCard(
          glow: true,
          padding: const EdgeInsets.all(26),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.7, -0.6),
                        radius: 1.2,
                        colors: <Color>[
                          t.accent.withValues(alpha: 0.14),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'OVERVIEW · 工作台',
                    style: TextStyle(
                      color: t.accent,
                      fontSize: 13,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$greet，115 会员',
                    style: TextStyle(
                      fontSize: 34,
                      height: 1.18,
                      fontWeight: FontWeight.w800,
                      color: t.textHi,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '本地资源发现与导入工作台 · 打开即推荐，输入即聚合，勾选即投递 115',
                    style: TextStyle(color: t.text),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        // KPI
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth > 900 ? 4 : 2;
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: cols,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 2.1,
              children: <Widget>[
                KpiTile(value: '$favCount', label: '收藏总数'),
                KpiTile(
                  value: '${stats['success'] ?? 0}',
                  label: '导入成功',
                  color: t.ok,
                ),
                KpiTile(
                  value: '$healthy / ${sources.length}',
                  label: '源健康度',
                  color: sources.isEmpty ? t.warn : t.ok,
                ),
                KpiTile(
                  value: session.phase.label,
                  label: '115 会话',
                  color: session.isLoggedIn
                      ? t.ok
                      : (session.phase == SessionPhase.failed ||
                                session.phase == SessionPhase.expired
                            ? t.danger
                            : t.textDim),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        // 网速诊断 + 导入看板
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 980;
            final speed = _SpeedCard();
            final board = _QueueBoard(
              rows: _rows,
              stats: stats,
              cloudNote: _cloudNote,
              busy: _cloudBusy,
              loggedIn: session.isLoggedIn,
              hideDetails: _hideTaskDetails,
              onToggleDetails: () =>
                  setState(() => _hideTaskDetails = !_hideTaskDetails),
              onRefresh: _pull,
            );
            if (!wide) {
              return Column(
                children: <Widget>[speed, const SizedBox(height: 16), board],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: speed),
                const SizedBox(width: 16),
                Expanded(child: board),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        // 快捷入口
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth > 900 ? 3 : 1;
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: cols,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: 3.4,
              children: <Widget>[
                _Shortcut(
                  icon: Icons.grid_view_outlined,
                  title: '去发现 →',
                  desc: '豆瓣海报墙 · 热门推荐',
                  index: 1,
                ),
                _Shortcut(
                  icon: Icons.search,
                  title: '去搜索 →',
                  desc: '多源聚合 · 去重排序',
                  index: 2,
                ),
                _Shortcut(
                  icon: Icons.download_for_offline_outlined,
                  title: '去导入 →',
                  desc: '扫码登录 · 任务看板',
                  index: 3,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Shortcut extends ConsumerWidget {
  const _Shortcut({
    required this.icon,
    required this.title,
    required this.desc,
    required this.index,
  });
  final IconData icon;
  final String title;
  final String desc;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    return HubCard(
      onTap: () => ref.read(navIndexProvider.notifier).select(index),
      child: Row(
        children: <Widget>[
          Icon(icon, color: t.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: t.textHi,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 3),
                Text(desc, style: TextStyle(color: t.textDim, fontSize: 13.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeedCard extends ConsumerStatefulWidget {
  const _SpeedCard();

  @override
  ConsumerState<_SpeedCard> createState() => _SpeedCardState();
}

class _SpeedCardState extends ConsumerState<_SpeedCard> {
  bool _measuring = false;
  double? _downMbps;
  String? _downErr;
  List<_NodeResult> _nodes = const <_NodeResult>[];
  String? _proxy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  Dio _dio() {
    final p = _proxy ?? '';
    final d = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        responseType: ResponseType.plain,
        followRedirects: true,
      ),
    );
    if (p.isNotEmpty) {
      d.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.findProxy = (uri) => 'PROXY $p';
          return c;
        },
      );
    }
    return d;
  }

  String _downValue() {
    if (_downErr != null) return '超时';
    if (_downMbps == null) return '—';
    return _downMbps!.toStringAsFixed(1);
  }

  double _downPct() {
    if (_downMbps == null) return 0.03;
    return (_downMbps! / 100).clamp(0.03, 1.0);
  }

  Future<void> _measure() async {
    _proxy = ref.read(appSettingsProvider).network.proxy;
    if (!mounted) return;
    setState(() {
      _measuring = true;
      _downMbps = null;
      _downErr = null;
      _nodes = const <_NodeResult>[];
    });

    // 真实下行测速：拉取少量字节，按 字节数/耗时 算 MB/s
    try {
      final sw = Stopwatch()..start();
      final res = await _dio().get<String>(
        'https://movie.douban.com/',
        options: Options(headers: <String, String>{'range': 'bytes=0-262143'}),
      );
      sw.stop();
      final bytes = (res.data ?? '').length;
      final secs = sw.elapsedMilliseconds / 1000.0;
      _downMbps = (secs > 0 && bytes > 0) ? bytes / secs / (1024 * 1024) : 0;
    } catch (_) {
      _downErr = '超时';
    }

    // 三个节点 RTT：各自独立测，单个失败不影响其他
    final targets = const <(String, String)>[
      ('115 节点', 'https://115.com/'),
      ('豆瓣', 'https://movie.douban.com/'),
      ('索引源', 'https://apibay.org'),
    ];
    final results = await Future.wait(
      targets.map((tg) async {
        try {
          final sw = Stopwatch()..start();
          await _dio().get<void>(tg.$2);
          sw.stop();
          return _NodeResult(tg.$1, sw.elapsedMilliseconds, null);
        } catch (_) {
          return _NodeResult(tg.$1, null, '超时');
        }
      }),
    );

    if (!mounted) return;
    setState(() {
      _nodes = results;
      _measuring = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      glow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '网速诊断',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              HubChip(
                label: _measuring ? '测速中' : '实时',
                selected: true,
                icon: _measuring ? Icons.sync : Icons.bolt,
                color: t.cyan,
              ),
              const SizedBox(width: 10),
              GhostButton(
                label: '重新测速',
                icon: Icons.refresh,
                onPressed: _measuring ? null : _measure,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_measuring) ...<Widget>[
            const SkeletonBox(height: 56, radius: 12, width: 280),
            const SizedBox(height: 16),
            for (int i = 0; i < 3; i++)
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: SkeletonBox(height: 16, radius: 8, width: 360),
              ),
          ] else ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: _Gauge(
                    label: '下行 MB/s',
                    value: _downValue(),
                    pct: _downPct(),
                    t: t,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: _Gauge(label: '上行 MB/s', value: '不实测', pct: 0, t: t),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final n in _nodes)
              _Node(name: n.name, ms: n.ms, err: n.err, t: t),
          ],
        ],
      ),
    );
  }
}

class _NodeResult {
  const _NodeResult(this.name, this.ms, this.err);
  final String name;
  final int? ms;
  final String? err;
}

class _Gauge extends StatelessWidget {
  const _Gauge({
    required this.label,
    required this.value,
    required this.pct,
    required this.t,
  });
  final String label;
  final String value;
  final double pct;
  final AppTokens t;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        value,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: t.textHi,
          height: 1,
        ),
      ),
      const SizedBox(height: 4),
      Text(label, style: TextStyle(color: t.textDim, fontSize: 13)),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: LinearProgressIndicator(
          value: pct,
          minHeight: 7,
          backgroundColor: t.bg0,
          valueColor: AlwaysStoppedAnimation<Color>(t.accent),
        ),
      ),
    ],
  );
}

class _Node extends StatelessWidget {
  const _Node({
    required this.name,
    required this.ms,
    required this.err,
    required this.t,
  });
  final String name;
  final int? ms;
  final String? err;
  final AppTokens t;

  @override
  Widget build(BuildContext context) {
    final failed = err != null;
    final color = failed ? t.danger : ((ms ?? 0) < 300 ? t.ok : t.warn);
    final pct = failed ? 0.03 : ((ms! / 600).clamp(0.05, 1.0)).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 84,
            child: Text(
              name,
              style: TextStyle(color: t.textDim, fontSize: 13.5),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 7,
                backgroundColor: t.bg0,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            failed ? err! : '${ms}ms',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 导入任务看板（W3）：不仅给计数，还要看到**每条任务的真实云端进度与资源名**
class _QueueBoard extends StatelessWidget {
  const _QueueBoard({
    required this.rows,
    required this.stats,
    required this.cloudNote,
    required this.busy,
    required this.loggedIn,
    required this.hideDetails,
    required this.onToggleDetails,
    required this.onRefresh,
  });

  final List<Map<String, Object?>> rows;
  final Map<String, int> stats;
  final String cloudNote;
  final bool busy;
  final bool loggedIn;

  /// 隐藏任务实例行（四项统计与同步状态仍保留）
  final bool hideDetails;

  final VoidCallback onToggleDetails;
  final Future<void> Function() onRefresh;

  /// 看板展示的任务条数上限（避免概览页被长列表撑爆）
  static const int _maxRows = 5;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // 优先展示进行中/排队，其次已完成：用户最关心的是"在跑什么、跑到哪了"
    final ordered = List<Map<String, Object?>>.from(rows)
      ..sort((a, b) {
        int rank(Map<String, Object?> r) => switch (r['status']?.toString()) {
          'running' => 0,
          'pending' => 1,
          'failed' => 2,
          _ => 3,
        };
        final d = rank(a).compareTo(rank(b));
        if (d != 0) return d;
        return ((b['id'] as num?)?.round() ?? 0).compareTo(
          (a['id'] as num?)?.round() ?? 0,
        );
      });

    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '导入任务看板',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: t.accent,
                    ),
                  ),
                ),
              GhostButton(
                label: hideDetails ? '显示详情' : '隐藏详情',
                icon: hideDetails
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                onPressed: onToggleDetails,
              ),
              const SizedBox(width: 8),
              GhostButton(
                label: '刷新进度',
                icon: Icons.sync,
                onPressed: busy ? null : () => onRefresh(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            loggedIn
                ? (cloudNote.isEmpty ? '正在读取 115 云端任务进度…' : cloudNote)
                : '未登录 115：看板仅显示本地队列状态，登录后可显示云端真实进度。',
            style: TextStyle(
              color: loggedIn ? t.textDim : t.warn,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              _Col('排队', stats['pending'] ?? 0, t.textDim, t),
              const SizedBox(width: 10),
              _Col('进行中', stats['running'] ?? 0, t.cyan, t),
              const SizedBox(width: 10),
              _Col('成功', stats['success'] ?? 0, t.ok, t),
              const SizedBox(width: 10),
              _Col('失败', stats['failed'] ?? 0, t.danger, t),
            ],
          ),
          // 详情区：隐藏时只收起任务实例行与条数提示，四项统计与同步状态始终保留。
          // AnimatedSize 负责高度过渡，AnimatedSwitcher 负责内容淡入淡出，
          // 两者配合避免展开/收起时卡片高度硬跳。
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              // 默认 layoutBuilder 会把新旧 child 叠在 Stack 里，高度取两者较大值，
              // 那样 AnimatedSize 就测不到「收起后的 0」；这里只放当前 child。
              layoutBuilder: (current, previous) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[?current],
              ),
              child: (hideDetails || ordered.isEmpty)
                  ? const SizedBox(key: ValueKey('queue-hidden'), height: 0)
                  : Column(
                      key: const ValueKey('queue-rows'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const SizedBox(height: 14),
                        for (final r in ordered.take(_maxRows))
                          _CloudTaskRow(row: r, t: t),
                        if (ordered.length > _maxRows)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '仅显示前 $_maxRows 条，完整队列见「导入」页。',
                              style: TextStyle(color: t.textDim, fontSize: 12),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条任务的云端进度行：资源名 + 状态 + 进度条 + 百分比
class _CloudTaskRow extends StatelessWidget {
  const _CloudTaskRow({required this.row, required this.t});
  final Map<String, Object?> row;
  final AppTokens t;

  @override
  Widget build(BuildContext context) {
    final status = row['status']?.toString() ?? 'pending';
    final color = switch (status) {
      'success' => t.ok,
      'failed' => t.danger,
      'running' => t.cyan,
      _ => t.textDim,
    };
    final progress = ((row['progress'] as num?)?.round() ?? 0).clamp(0, 100);
    final title = (row['title']?.toString().isNotEmpty ?? false)
        ? row['title'].toString()
        : (row['target']?.toString() ?? '');
    final msg = row['message']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.bg1,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusDot(color: color, size: 8),
              const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: title,
                  child: Text(
                    title.isEmpty ? '（未命名任务）' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textHi,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$progress%',
                style: TextStyle(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress / 100,
              minHeight: 6,
              backgroundColor: t.bg0,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          if (msg.isNotEmpty) ...<Widget>[
            const SizedBox(height: 5),
            Text(
              msg,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textDim, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _Col extends StatelessWidget {
  const _Col(this.label, this.count, this.color, this.t);
  final String label;
  final int count;
  final Color color;
  final AppTokens t;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: t.bg1,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: <Widget>[
          Text(
            '$count',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: t.textDim, fontSize: 12.5)),
        ],
      ),
    ),
  );
}
