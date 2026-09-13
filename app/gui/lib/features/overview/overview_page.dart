import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repos.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../sources/source.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final db = ref.watch(appDatabaseProvider).maybeValue;
    final session = ref.watch(sessionProvider);

    final favCount = db == null ? 0 : FavoritesRepo(db).count();
    final stats = db == null
        ? <String, int>{'pending': 0, 'running': 0, 'success': 0, 'failed': 0}
        : ImportRepo(db).stats();
    final sources = db == null ? <SourceLite>[] : SourceRepo(db).listAll();
    final healthy = sources.where((s) => s.enabled).length;
    final hour = DateTime.now().hour;
    final greet = hour < 6 ? '凌晨好' : (hour < 12 ? '早上好' : (hour < 18 ? '下午好' : '晚上好'));

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
                  Text('OVERVIEW · 工作台',
                      style: TextStyle(
                          color: t.accent,
                          fontSize: 13,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text('$greet，115 会员',
                      style: TextStyle(
                          fontSize: 34,
                          height: 1.18,
                          fontWeight: FontWeight.w800,
                          color: t.textHi)),
                  const SizedBox(height: 6),
                  Text('本地资源发现与导入工作台 · 打开即推荐，输入即聚合，勾选即投递 115',
                      style: TextStyle(color: t.text)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        // KPI
        LayoutBuilder(builder: (context, c) {
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
                  color: t.ok),
              KpiTile(
                  value: '$healthy / ${sources.length}',
                  label: '源健康度',
                  color: sources.isEmpty ? t.warn : t.ok),
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
        }),
        const SizedBox(height: 18),
        // 网速诊断 + 导入看板
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 980;
          final speed = _SpeedCard();
          final board = _QueueBoard(stats: stats);
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
        }),
        const SizedBox(height: 18),
        // 快捷入口
        LayoutBuilder(builder: (context, c) {
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
                  index: 1),
              _Shortcut(
                  icon: Icons.search, title: '去搜索 →', desc: '多源聚合 · 去重排序', index: 2),
              _Shortcut(
                  icon: Icons.download_for_offline_outlined,
                  title: '去导入 →',
                  desc: '扫码登录 · 任务看板',
                  index: 3),
            ],
          );
        }),
      ],
    );
  }
}

class _Shortcut extends ConsumerWidget {
  const _Shortcut(
      {required this.icon, required this.title, required this.desc, required this.index});
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
                Text(title,
                    style: TextStyle(
                        color: t.textHi, fontWeight: FontWeight.w700, fontSize: 16)),
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
    final d = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      responseType: ResponseType.plain,
      followRedirects: true,
    ));
    if (p.isNotEmpty) {
      d.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final c = HttpClient();
        c.findProxy = (uri) => 'PROXY $p';
        return c;
      });
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
    final results = await Future.wait(targets.map((tg) async {
      try {
        final sw = Stopwatch()..start();
        await _dio().get<void>(tg.$2);
        sw.stop();
        return _NodeResult(tg.$1, sw.elapsedMilliseconds, null);
      } catch (_) {
        return _NodeResult(tg.$1, null, '超时');
      }
    }));

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
                child: Text('网速诊断',
                    style: TextStyle(
                        color: t.textHi, fontSize: 18, fontWeight: FontWeight.w700)),
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
                  child: _Gauge(
                    label: '上行 MB/s',
                    value: '不实测',
                    pct: 0,
                    t: t,
                  ),
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
  const _Gauge({required this.label, required this.value, required this.pct, required this.t});
  final String label;
  final String value;
  final double pct;
  final AppTokens t;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value,
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: t.textHi,
                  height: 1)),
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
  const _Node({required this.name, required this.ms, required this.err, required this.t});
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
            child: Text(name, style: TextStyle(color: t.textDim, fontSize: 13.5)),
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
          Text(failed ? err! : '${ms}ms',
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13.5)),
        ],
      ),
    );
  }
}

class _QueueBoard extends StatelessWidget {
  const _QueueBoard({required this.stats});
  final Map<String, int> stats;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('导入任务看板',
              style: TextStyle(color: t.textHi, fontSize: 18, fontWeight: FontWeight.w700)),
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
              Text('$count',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800, color: color)),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(color: t.textDim, fontSize: 12.5)),
            ],
          ),
        ),
      );
}
