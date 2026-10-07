import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../../core/db/settings.dart';
import '../../core/media/media_grouping.dart';
import '../../core/media/media_index_store.dart';
import '../../core/media/media_scan_gateway.dart';
import '../../core/media/media_title_parser.dart';
import '../../core/util/logger.dart';
import '../../state/providers.dart';
import '../../ui/hm_symbols.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'local_video_scanner.dart';
import 'media_playback_error.dart';
import 'media_player_view.dart';
import 'media_source.dart';
import 'pan115_browser.dart';

/// 4.1 媒体库页面（v2.3 会话化改造）：
///
/// * **索引优先**：页面首次展示先读 [MediaIndexStore] 落盘的索引 JSON，
///   自动按作品分组归类 —— 重启不重扫，列表秒开；索引不存在才自动扫描
///   （首次探查的结果由网关落盘，下次启动即命中索引）；
/// * **会话式扫描**：走 [startMediaDirectory] 会话，进度条 + 暂停/继续/取消
///   （native 后台线程，暂停不重扫）；结果落盘与列表展示彻底解耦；
/// * **工具栏收敛**：扫描路径不再常显 —— 右上角两枚 HarmonyOS Symbol 图标
///   （切源 / 添加）承载源切换与路径录入，悬停显示简单文本；
/// * **作品分组**（B1-3）：[groupMedia] 按 contentKey 聚合，剧集收拢展示。
///
/// 【仍然刻意不做】海报墙、TMDB 刮削、播放记录持久化 —— 属后续批次。
class MediaPage extends ConsumerStatefulWidget {
  const MediaPage({super.key});

  @override
  ConsumerState<MediaPage> createState() => _MediaPageState();
}

enum _MediaTab { local, pan115 }

/// 正在播放的条目：本地文件与网盘直链统一成「标题 + 副题 + 源」。
///
/// 【凭证红线】远程源的鉴权头只存在于 [source] 内部（Media.httpHeaders），
/// 本类与任何日志、序列化路径都不允许出现它的内容；对外描述一律走
/// [MediaSource.describe]（只报 scheme/host/有无 header）。
class _Playing {
  const _Playing({
    required this.title,
    required this.subtitle,
    required this.source,
  });

  final String title;
  final String subtitle;
  final Media source;
}

class _MediaPageState extends ConsumerState<MediaPage> {
  _MediaTab _tab = _MediaTab.local;

  // ── 列表态 ──
  List<MediaGroup> _groups = const <MediaGroup>[];
  int _fileCount = 0;
  final Set<String> _expanded = <String>{};
  _Playing? _current;
  String? _notice;
  String _backend = '';

  // ── 扫描会话态 ──
  MediaScanHandle? _scan;
  StreamSubscription<MediaScanProgress>? _progressSub;
  bool _scanning = false;
  bool _scanPaused = false;
  bool _cancelRequested = false; // 用户点了取消：区分「取消」与「扫到空目录」
  int _scanFiles = 0;
  String _scannedDir = '';
  int _scanSeq = 0; // 防陈旧结果：连续扫描时只认最后一次

  @override
  void initState() {
    super.initState();
    // 首帧后做初始装载：读索引 → 命中即展示；未命中且有配置目录 → 自动扫描
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initialLoad();
    });
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _scan?.cancel();
    super.dispose();
  }

  /// 初始装载：**只读 JSON，不扫描**。索引命中 → 直接分组展示（重启秒开）；
  /// 未命中且有配置目录 → 自动探查一次（结果由网关落盘，此后重启走索引）。
  void _initialLoad() {
    final String dir = ref
        .read(appSettingsProvider.select((AppSettings s) => s.media.directory))
        .trim();
    if (dir.isEmpty) return;
    final MediaIndex? idx = MediaIndexStore.load(dir);
    if (idx != null) {
      _applyIndex(idx);
      HubLogger.d(
        'media: index hit $dir -> files=${idx.entries.length} '
        'backend=${idx.backend} scannedAt=${idx.scannedAtMs}',
      );
      return;
    }
    _startScan(dir);
  }

  /// 索引 → 自动分组归类（任务：首次显示视频列表时读取 json 内容自动整理）
  void _applyIndex(MediaIndex idx) {
    final List<MediaGroupItem> items = <MediaGroupItem>[
      for (final MediaScanEntry e in idx.entries)
        MediaGroupItem(
          path: e.path,
          name: e.name,
          sizeBytes: e.sizeBytes,
          info: MediaTitleParser.parse(e.name, pathHints: _hintsOf(e.path)),
        ),
    ];
    setState(() {
      _groups = groupMedia(items);
      _fileCount = items.length;
      _backend = 'index:${idx.backend}';
      _scannedDir = idx.root;
      _notice = items.isEmpty ? '索引里没有视频文件，可点右上角 + 重新扫描' : null;
      _expanded
        ..clear()
        ..addAll(_groups.where((g) => !g.isSingle).map((g) => g.contentKey));
    });
  }

  /// 配置里的目录到位后自动探查一次。
  /// 必须走 post-frame：`ref.listen` 的回调可能在 build 期间触发。
  void _scheduleScan(String dir) {
    if (dir.isEmpty || dir == _scannedDir || _scanning) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startScan(dir);
    });
  }

  /// 会话式扫描：进度条 + 暂停/取消。取消保留原列表（用户可能只是手滑）。
  Future<void> _startScan(String rawDir) async {
    final String dir = rawDir.trim();
    if (dir.isEmpty) return;
    _scannedDir = dir;
    final int seq = ++_scanSeq;

    if (!Directory(dir).existsSync()) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _notice = '目录不存在或无法访问：$dir';
      });
      return;
    }

    _progressSub?.cancel();
    _scan?.cancel();
    setState(() {
      _scanning = true;
      _scanPaused = false;
      _cancelRequested = false;
      _scanFiles = 0;
      _notice = null;
    });

    final MediaScanHandle handle = startMediaScan(
      dir,
      maxDepth: 8,
      maxFiles: 4000,
    );
    _scan = handle;
    _progressSub = handle.onProgress.listen((MediaScanProgress p) {
      if (!mounted || seq != _scanSeq) return;
      setState(() {
        _scanPaused = p.state == 'paused';
        _scanFiles = p.files;
      });
    });

    final MediaScanResult r;
    try {
      r = await handle.result;
    } catch (e) {
      HubLogger.w('media: scan failed $dir', e);
      if (!mounted || seq != _scanSeq) return;
      setState(() {
        _scanning = false;
        _scan = null;
        _notice = '扫描失败（原生与回退引擎都不可用）';
      });
      return;
    }
    if (!mounted || seq != _scanSeq) return;
    _scan = null;

    if (r.isEmpty && _cancelRequested) {
      // 取消：保留原列表，如实提示
      setState(() {
        _scanning = false;
        _notice = '已取消扫描（保留原列表）';
      });
      return;
    }

    final List<MediaGroupItem> items = <MediaGroupItem>[
      for (final MediaScanEntry e in r.entries)
        MediaGroupItem(
          path: e.path,
          name: e.name,
          sizeBytes: e.sizeBytes,
          info: MediaTitleParser.parse(e.name, pathHints: _hintsOf(e.path)),
        ),
    ];
    final List<MediaGroup> groups = groupMedia(items);
    HubLogger.d(
      'media: scan $dir -> files=${items.length} works=${groups.length} '
      'backend=${r.backend}',
    );

    // 单条目组直接视为「已展开」（渲染为普通行）；多集剧集默认收起
    setState(() {
      _groups = groups;
      _fileCount = items.length;
      _backend = r.backend;
      _scanning = false;
      _notice = items.isEmpty
          ? '这个目录树里没有找到视频文件（支持 ${LocalVideoScanner.extensions.join(' / ')}）'
          : null;
    });
  }

  /// 逐文件的目录提示（由近及远）：父目录名优先，祖父次之。
  /// 如 Y:\电视剧\伪装者.2015\E01.mkv → ['伪装者.2015', '电视剧']。
  static List<String> _hintsOf(String path) {
    final String parent = p.basename(p.dirname(path));
    final String grand = p.basename(p.dirname(p.dirname(path)));
    return <String>[parent, grand];
  }

  // ── 工具栏动作 ──

  /// 「添加本地路径扫描」弹窗：路径默认隐藏，从图标进入（悬停文案「添加（添加
  /// 本地路径扫描）」）。确认 = 写回设置 + 立即扫描。
  Future<void> _showAddDialog() async {
    final AppTokens t = context.t;
    final TextEditingController ctrl = TextEditingController(text: _scannedDir);
    final String? dir = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: t.surface1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: t.border),
        ),
        title: Text(
          '添加本地路径扫描',
          style: TextStyle(
            color: t.textHi,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '填入视频根目录，将递归扫描全部子目录。'
                '支持 ${LocalVideoScanner.extensions.join(' / ')}',
                style: TextStyle(color: t.textDim, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: TextStyle(color: t.textHi, fontSize: 13),
                decoration: InputDecoration(
                  hintText: r'例如 D:\Media',
                  hintStyle: TextStyle(color: t.textDim, fontSize: 13),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: t.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: t.border),
                  ),
                ),
                onSubmitted: (String v) => Navigator.of(ctx).pop(v.trim()),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: t.textDim, fontSize: 13)),
          ),
          AccentButton(
            label: '开始扫描',
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
          ),
        ],
      ),
    );
    if (dir == null || dir.isEmpty) return;
    ref
        .read(appSettingsProvider.notifier)
        .patchMedia(MediaSettings(directory: dir));
    _startScan(dir);
  }

  void _playLocal(MediaGroupItem item) {
    setState(() {
      _current = _Playing(
        title: item.info.hasTitle ? item.info.title : item.name,
        subtitle: item.name,
        source: MediaSource.media(Uri.file(item.path).toString()),
      );
    });
  }

  /// 网盘直链播放（B1-4）。url/headers 由 Pan115Browser 取链后回调；
  /// 取链失败的信息它在浏览器侧就地展示，这里只接成功路径。
  void _playRemote(String url, Map<String, String> headers, String title) {
    setState(() {
      _current = _Playing(
        title: title,
        subtitle: '115 网盘直链',
        source: MediaSource.media(url, httpHeaders: headers),
      );
    });
  }

  /// 播放失败的**用户可见**反馈。
  void _onPlayError(MediaPlaybackError e) =>
      _toast('${e.headline}：${e.suggestion}');

  void _toast(String msg) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AppTokens t = context.t;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            backgroundColor: t.surface3,
            content: Text(
              msg,
              style: TextStyle(color: t.textHi, fontSize: 13, height: 1.5),
            ),
          ),
        );
    });
  }

  @override
  Widget build(BuildContext context) {
    final String configured = ref.watch(
      appSettingsProvider.select((AppSettings s) => s.media.directory),
    );
    ref.listen<String>(
      appSettingsProvider.select((AppSettings s) => s.media.directory),
      (String? prev, String next) => _scheduleScan(next),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildToolbar(),
        if (_scanning) ...<Widget>[
          const SizedBox(height: 8),
          _buildScanProgress(),
        ],
        const SizedBox(height: 12),
        Expanded(
          child: _tab == _MediaTab.pan115
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(width: 380, child: _buildPanBrowser()),
                    const SizedBox(width: 12),
                    Expanded(child: _buildStage()),
                  ],
                )
              : configured.trim().isEmpty
              ? _buildChooseDir()
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(width: 340, child: _buildList()),
                    const SizedBox(width: 12),
                    Expanded(child: _buildStage()),
                  ],
                ),
        ),
      ],
    );
  }

  /// 工具栏：扫描路径**不再常显** —— 右上角两枚 HarmonyOS Symbol 图标按钮
  /// （参考主流桌面应用：小圆角方块，悬停显示简单文本说明）。
  /// 切源 = PopupMenu（本地 / 115 网盘，当前项打勾）。
  Widget _buildToolbar() {
    final AppTokens t = context.t;
    return Row(
      children: <Widget>[
        Text(
          _tab == _MediaTab.local ? '本地视频' : '115 网盘',
          style: TextStyle(
            color: t.textHi,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        PopupMenuButton<_MediaTab>(
          tooltip: '切源（115 和本地切换）',
          color: t.surface1,
          elevation: 8,
          offset: const Offset(0, 42),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: t.border),
          ),
          onSelected: (_MediaTab v) {
            if (v == _tab) return;
            setState(() => _tab = v);
          },
          itemBuilder: (_) => <PopupMenuEntry<_MediaTab>>[
            _sourceItem(_MediaTab.local, '本地', Icons.video_library_outlined),
            _sourceItem(_MediaTab.pan115, '115 网盘', Icons.cloud_outlined),
          ],
          child: _SquareIconFace(icon: HmSymbols.swap, size: 34),
        ),
        const SizedBox(width: 8),
        _SquareIconButton(
          icon: HmSymbols.plus,
          tooltip: '添加（添加本地路径扫描）',
          onPressed: _showAddDialog,
        ),
      ],
    );
  }

  PopupMenuItem<_MediaTab> _sourceItem(_MediaTab v, String label, IconData ic) {
    final AppTokens t = context.t;
    final bool selected = _tab == v;
    return PopupMenuItem<_MediaTab>(
      value: v,
      height: 40,
      child: Row(
        children: <Widget>[
          Icon(ic, size: 16, color: selected ? t.accent : t.textDim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: selected ? t.accent : t.textHi,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
          if (selected) Icon(Icons.check, size: 16, color: t.accent),
        ],
      ),
    );
  }

  /// 扫描进度条：已发现文件数 + 暂停/继续 + 取消（HarmonyOS Symbol 图标）
  Widget _buildScanProgress() {
    final AppTokens t = context.t;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _scanPaused
                ? '扫描已暂停 · 已发现 $_scanFiles 个视频'
                : '扫描中 · 已发现 $_scanFiles 个视频',
            style: TextStyle(color: t.textDim, fontSize: 12),
          ),
        ),
        _SquareIconButton(
          icon: _scanPaused ? HmSymbols.play : HmSymbols.pause,
          size: 30,
          tooltip: _scanPaused ? '继续扫描' : '暂停扫描',
          onPressed: () {
            final MediaScanHandle? h = _scan;
            if (h == null) return;
            if (_scanPaused) {
              h.resume();
            } else {
              h.pause();
            }
          },
        ),
        const SizedBox(width: 6),
        _SquareIconButton(
          icon: HmSymbols.xmark,
          size: 30,
          tooltip: '取消扫描',
          onPressed: () {
            _cancelRequested = true;
            _scan?.cancel();
          },
        ),
      ],
    );
  }

  /// 未配置目录时的入口：**明确告诉用户要做什么**，同时不去扫任何默认位置。
  Widget _buildChooseDir() {
    final AppTokens t = context.t;
    return HubCard(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.video_library_outlined, size: 48, color: t.textDim),
            const SizedBox(height: 12),
            Text(
              '还没有设置本地视频目录',
              style: TextStyle(
                color: t.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '点右上角的「+」填入视频根目录后开始扫描。'
              '会递归搜索全部子目录；本页不会替你猜目录、也不会自动扫描任何默认位置。',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textDim, fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 8),
            Text(
              '支持 ${LocalVideoScanner.extensions.join(' / ')}',
              style: TextStyle(color: t.textDim, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    final AppTokens t = context.t;
    final String backendLabel = switch (_backend) {
      'native' => '原生扫描引擎',
      'dart' => 'Dart 回退',
      final String b when b.startsWith('index:') => '索引缓存',
      _ => '',
    };
    return HubCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: <Widget>[
                Text(
                  _groups.isEmpty
                      ? '本地视频'
                      : '本地视频 · $_fileCount 个文件 · ${_groups.length} 个作品',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (backendLabel.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 8),
                  HubChip(
                    label: backendLabel,
                    color: _backend == 'dart' ? t.warn : t.ok,
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: t.border),
          Expanded(child: _buildListBody()),
        ],
      ),
    );
  }

  Widget _buildListBody() {
    final AppTokens t = context.t;
    if (_notice != null && !_scanning) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _notice!,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textDim, fontSize: 12, height: 1.5),
          ),
        ),
      );
    }
    if (_groups.isEmpty) {
      return Center(
        child: Text(
          _scanning ? '等待扫描结果…' : '没有可播放的视频',
          style: TextStyle(color: t.textDim, fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      itemCount: _groups.length,
      itemBuilder: (BuildContext context, int i) => _buildGroupRow(_groups[i]),
    );
  }

  /// 一个作品行：单条目=普通行；多条目=可展开的「剧/系列」头 + 子行。
  Widget _buildGroupRow(MediaGroup g) {
    final AppTokens t = context.t;
    if (g.isSingle) {
      final MediaGroupItem it = g.items.first;
      return _buildLeafRow(
        title: g.label,
        subtitle: it.name,
        sizeBytes: it.sizeBytes,
        path: it.path,
        indent: false,
        trailing: g.kind == MediaTitleKind.tv ? '单集' : null,
        onTap: () => _playLocal(it),
      );
    }

    final bool open = _expanded.contains(g.contentKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() {
            open ? _expanded.remove(g.contentKey) : _expanded.add(g.contentKey);
          }),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            decoration: BoxDecoration(
              color: open ? t.surface2.withValues(alpha: 0.5) : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: <Widget>[
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Icon(Icons.chevron_right, size: 18, color: t.textDim),
                ),
                const SizedBox(width: 6),
                Icon(
                  g.kind == MediaTitleKind.tv
                      ? Icons.live_tv_outlined
                      : Icons.movie_outlined,
                  size: 18,
                  color: t.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    g.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textHi,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  g.subtitle.isEmpty ? '${g.items.length} 个版本' : g.subtitle,
                  style: TextStyle(color: t.textDim, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final MediaGroupItem it in g.items)
                  _buildLeafRow(
                    title: episodeLabel(it),
                    subtitle: episodeSubtitle(it),
                    sizeBytes: it.sizeBytes,
                    path: it.path,
                    indent: true,
                    trailing: null,
                    onTap: () => _playLocal(it),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLeafRow({
    required String title,
    required String subtitle,
    required int sizeBytes,
    required String path,
    required bool indent,
    required String? trailing,
    required VoidCallback onTap,
  }) {
    final AppTokens t = context.t;
    final bool selected = _current?.subtitle == path;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      selected: selected,
      selectedColor: t.accent,
      selectedTileColor: t.surface2,
      contentPadding: EdgeInsets.only(left: indent ? 8 : 4, right: 12),
      leading: Icon(
        Icons.movie_outlined,
        size: 16,
        color: selected ? t.accent : t.textDim,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: selected ? t.accent : t.textHi,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.textDim, fontSize: 11),
      ),
      trailing: Text(
        trailing ??
            (sizeBytes <= 0
                ? ''
                : '${(sizeBytes / 1048576).toStringAsFixed(1)} MB'),
        style: TextStyle(color: t.textDim, fontSize: 11),
      ),
      onTap: onTap,
    );
  }

  Widget _buildPanBrowser() {
    // 未登录 / 加载 / 空目录 / 错误四态全由 Pan115Browser 内部自持
    // （含「去导入页扫码」按钮），这里不再套一层引导卡 —— 一个事实一处真相，
    // 避免两处文案不同步。注意：它需要**有界高度**，故套在 Row 的固定宽度里。
    return HubCard(
      padding: EdgeInsets.zero,
      child: Pan115Browser(onPlay: _playRemote),
    );
  }

  Widget _buildStage() {
    final AppTokens t = context.t;
    final _Playing? current = _current;
    if (current == null) {
      return HubCard(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.play_circle_outline, size: 48, color: t.textDim),
              const SizedBox(height: 12),
              Text(
                '从左侧选择一个视频开始播放',
                style: TextStyle(color: t.textDim, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }
    return HubCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    current.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.textHi,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    current.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.textDim, fontSize: 11),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                // 播放源统一经 MediaSource.media 构造（含网盘直链的鉴权头）；
                // 全屏 = 窗口真全屏（media_player_view.dart 里 onEnter/ExitFullscreen）。
                child: MediaPlayerView(
                  key: ValueKey<String>(current.source.uri),
                  source: current.source,
                  onError: _onPlayError,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 右上角小圆角方块图标按钮（对齐参考稿：小方块 + 单色图标，悬停显示简单
/// 文本说明）。图标统一取 HarmonyOS Symbol（Apache-2.0）。
class _SquareIconButton extends StatelessWidget {
  const _SquareIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 34,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.t;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: Material(
        color: t.surface2,
        borderRadius: BorderRadius.circular(size * 0.3),
        child: InkWell(
          borderRadius: BorderRadius.circular(size * 0.3),
          onTap: onPressed,
          hoverColor: t.surface3,
          child: _SquareIconFace(icon: icon, size: size),
        ),
      ),
    );
  }
}

/// 方块按钮的视觉面（无手势）：PopupMenuButton 等自带手势的容器也能复用
class _SquareIconFace extends StatelessWidget {
  const _SquareIconFace({required this.icon, required this.size});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: t.border),
      ),
      child: Icon(icon, size: size * 0.52, color: t.textHi),
    );
  }
}
