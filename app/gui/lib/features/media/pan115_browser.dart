import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation/app_route.dart';
import '../../core/network/pan115_files.dart';
import '../../core/network/pan115_playlink.dart';
import '../../core/util/logger.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// 115 网盘浏览页（B1-4 / P 批次）——**自包含**，D2 只负责挂到媒体页的 tab 上。
///
/// 【红线】cookie 只从内存会话（`sessionProvider`）取用，不落盘、不进日志；
/// 失败文案由 `pan115_files.dart` / `pan115_playlink.dart` 出具，本页只做原样转述。
///
/// 【为什么不假装能播】`docs/Spike-B1-S7-115网盘直链可行性.md` 已实测：
/// 现有登录渠道的 cookie 通 `aps.115.com`（能列目录），但通不了
/// `webapi.115.com`（取直链），后者恒返 990001。因此本页如实展示原因与解锁路径，
/// **绝不伪造可播地址**。
class Pan115Browser extends ConsumerStatefulWidget {
  const Pan115Browser({super.key, required this.onPlay});

  /// 取链成功后交给外壳播放：直链 + 必须随请求带的头 + 标题
  final void Function(String url, Map<String, String> headers, String title)
  onPlay;

  @override
  ConsumerState<Pan115Browser> createState() => _Pan115BrowserState();
}

/// 根目录：115 的列目录接口用 cid=0 表示根
const String kPan115RootCid = '0';
const String kPan115RootName = '全部文件';

/// 面包屑上的一级
class _Crumb {
  const _Crumb(this.cid, this.name);
  final String cid;
  final String name;
}

class _Pan115BrowserState extends ConsumerState<Pan115Browser> {
  final List<_Crumb> _crumbs = <_Crumb>[
    const _Crumb(kPan115RootCid, kPan115RootName),
  ];
  List<Pan115Node> _nodes = const <Pan115Node>[];
  String? _error;
  bool _loading = false;

  /// 正在取链的 pickcode（行内转圈），同一时刻只处理一个
  String? _linkingPc;

  /// 首屏只自动加载一次；登出后归零，方便重新登录后自动重来
  bool _bootstrapped = false;

  String get _currentCid => _crumbs.last.cid;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final loggedIn = session.isLoggedIn && session.cookie.isNotEmpty;

    if (loggedIn && !_bootstrapped) {
      _bootstrapped = true;
      // 会话可能在别的页面（115 导入）刚建立，此时 build 正在跑，
      // 直接 setState 会炸，统一推到帧后
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadDir(kPan115RootCid);
      });
    } else if (!loggedIn) {
      _bootstrapped = false;
    }

    if (!loggedIn) return _buildLoginGuide();

    return HubCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildHeader(),
          Divider(height: 1, color: context.t.border),
          if (_error != null) _buildErrorBanner(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 未登录引导

  Widget _buildLoginGuide() {
    final t = context.t;
    return HubCard(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cloud_off_outlined, size: 48, color: t.textDim),
            const SizedBox(height: 12),
            Text(
              '未登录 115，无法浏览网盘',
              style: TextStyle(
                color: t.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '网盘浏览用的是会话 cookie（只存在内存里），'
              '请先到「115 导入」页扫码登录，登录后回到本页会自动加载。',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textDim, fontSize: 12, height: 1.6),
            ),
            const SizedBox(height: 14),
            AccentButton(
              label: '去 115 导入页登录',
              icon: Icons.qr_code_2_outlined,
              onPressed: () =>
                  ref.read(navIndexProvider.notifier).select(AppRoute.import),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------- 头部

  Widget _buildHeader() {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (var i = 0; i < _crumbs.length; i++) _buildCrumb(i, t),
            ],
          ),
          const SizedBox(height: 6),
          // 直链受鉴权域限制是本功能的已知边界，明写在页头，
          // 避免用户点开被拒时以为是软件坏了（对齐设计文档 §3 的交付口径）
          Text(
            '直链播放受 115 鉴权域限制：当前登录渠道可能被拒绝（990001），'
            '届时会如实提示，不会伪造可播地址。',
            style: TextStyle(color: t.textDim, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildCrumb(int i, AppTokens t) {
    final c = _crumbs[i];
    final last = i == _crumbs.length - 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (i > 0) Icon(Icons.chevron_right, size: 14, color: t.textDim),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: last || _loading ? null : () => _gotoCrumb(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              c.name,
              style: TextStyle(
                color: last ? t.textHi : t.accent,
                fontSize: 12,
                fontWeight: last ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBanner() {
    final t = context.t;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, size: 16, color: t.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(color: t.textHi, fontSize: 12, height: 1.5),
            ),
          ),
          const SizedBox(width: 8),
          GhostButton(label: '重试', onPressed: _loading ? null : _reload),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------- 主体

  Widget _buildBody() {
    final t = context.t;
    if (_loading && _nodes.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_nodes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            // 有错误时页内横幅已经解释了原因，这里不再重复一句
            _error == null ? '这个目录里没有条目' : '',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textDim, fontSize: 12),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _nodes.length,
      itemBuilder: (BuildContext context, int i) => _buildRow(_nodes[i]),
    );
  }

  Widget _buildRow(Pan115Node node) {
    final t = context.t;
    final busy = _linkingPc == node.pickcode;
    final Widget leading = busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            node.isDir
                ? Icons.folder_outlined
                : (node.isVideo
                      ? Icons.movie_outlined
                      : Icons.insert_drive_file_outlined),
            size: 18,
            color: node.isVideo ? t.accent : t.textDim,
          );

    return ListTile(
      dense: true,
      leading: leading,
      title: Text(
        node.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: node.isVideo ? t.textHi : t.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: node.isDir
          ? null
          : Text(
              _subtitleOf(node),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textDim, fontSize: 11),
            ),
      trailing: node.isDir
          ? Icon(Icons.chevron_right, size: 16, color: t.textDim)
          : (node.isVideo
                ? Icon(Icons.play_arrow_rounded, size: 18, color: t.accent)
                : null),
      onTap: busy ? null : () => _onTapNode(node),
    );
  }

  String _subtitleOf(Pan115Node node) {
    final parts = <String>[_fmtSize(node.sizeBytes)];
    if (node.playLongSec > 0) parts.add(_fmtDuration(node.playLongSec));
    if (node.ext.isNotEmpty && node.ext != node.ico) {
      // ico 与文件名后缀不一致时（115 偶发）把两者都摆出来，便于用户判断真伪
      parts.add(node.ext);
    }
    return parts.join(' · ');
  }

  // ------------------------------------------------------------------- 交互

  void _onTapNode(Pan115Node node) {
    if (node.isDir) {
      setState(() {
        _crumbs.add(_Crumb(node.fid, node.name));
      });
      _loadDir(node.fid);
      return;
    }
    if (!node.isVideo) {
      // 点了不该没反应：明说为什么不能播（后缀来自 115 自己给的 ico/文件名）
      setState(() {
        _error = node.ext.isEmpty
            ? '「${node.name}」不是可播的视频格式'
            : '「${node.name}」不是可播的视频格式（.${node.ext}）';
      });
      return;
    }
    _openVideo(node);
  }

  void _gotoCrumb(int index) {
    if (index < 0 || index >= _crumbs.length) return;
    setState(() {
      _crumbs.removeRange(index + 1, _crumbs.length);
    });
    _loadDir(_currentCid);
  }

  void _reload() => _loadDir(_currentCid);

  Future<void> _loadDir(String cid) async {
    final cookie = ref.read(sessionProvider).cookie;
    if (cookie.isEmpty) return;
    final proxy = ref.read(appSettingsProvider).network.proxy;

    setState(() {
      _loading = true;
      _error = null;
    });
    final listing = await fetchPan115Listing(
      cookie: cookie,
      cid: cid,
      proxy: proxy,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _nodes = listing.nodes;
      _error = listing.ok ? null : listing.message;
    });
  }

  Future<void> _openVideo(Pan115Node node) async {
    final cookie = ref.read(sessionProvider).cookie;
    if (cookie.isEmpty) return;
    final proxy = ref.read(appSettingsProvider).network.proxy;

    setState(() {
      _linkingPc = node.pickcode;
      _error = null;
    });
    final link = await fetchPan115DownloadUrl(
      cookie: cookie,
      pickcode: node.pickcode,
      proxy: proxy,
    );
    if (!mounted) return;
    setState(() => _linkingPc = null);
    if (!link.ok) {
      // 原样转述取链层给出的原因（不含任何凭证）
      setState(() => _error = link.message);
      return;
    }
    widget.onPlay(link.url, pan115PlayHeaders(cookie), node.name);
  }

  static String _fmtSize(int bytes) {
    if (bytes <= 0) return '未知大小';
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  static String _fmtDuration(int sec) {
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    // 插值后紧跟中文不需要花括号：Dart 不会把 Unicode 字母并入变量名，
    // 故统一按 lint 建议写成 $m（与下一行 $h 保持一致）。
    if (h <= 0) return '$m分';
    return '$h时${m.toString().padLeft(2, '0')}分';
  }
}

/// 列目录：`GET https://aps.115.com/natsort/files.php?cid=<cid>`（需会话 cookie）
const String kPan115FilesApi = 'https://aps.115.com/natsort/files.php';

/// 115 最小请求间隔（毫秒）。
///
/// 依据：spike §2 Q5 —— 项目 native 侧本来就为 115 准备了 1 req/s 限流器，
/// 说明该站点确实有频率风控；连续翻目录是最容易撞风控的动作，这里单独挡一道。
const int kPan115MinRequestIntervalMs = 600;

/// 最近一次列目录请求的时刻（模块级：本页是 files.php 的唯一调用方）
DateTime? _lastListingAt;

/// 取一个目录的条目列表。
///
/// 【为什么这个网络调用放在 UI 文件里】本批只允许新增 `pan115_files.dart`（纯解析，
/// 禁 IO）、`pan115_playlink.dart`（取直链）、本文件三个文件，而列目录只有本页
/// 一个消费方。放在解析层会破坏「纯 Dart 可复跑」的红线，为此再开一个文件又属于
/// 过度抽象，因此就地实现，解析仍复用 `parsePan115FileList`。
Future<Pan115Listing> fetchPan115Listing({
  required String cookie,
  required String cid,
  String proxy = '',
  int timeoutMs = 10000,
}) async {
  if (cookie.isEmpty) {
    return const Pan115Listing(ok: false, message: '未登录 115，无法列目录');
  }

  // 限流：与上一次 115 请求至少间隔 600ms
  final last = _lastListingAt;
  if (last != null) {
    final wait =
        kPan115MinRequestIntervalMs -
        DateTime.now().difference(last).inMilliseconds;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
  }
  _lastListingAt = DateTime.now();

  final d = Dio(
    BaseOptions(
      connectTimeout: Duration(milliseconds: timeoutMs),
      receiveTimeout: Duration(milliseconds: timeoutMs),
      responseType: ResponseType.plain,
      followRedirects: true,
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

  final url = '$kPan115FilesApi?cid=${Uri.encodeComponent(cid)}';
  try {
    final res = await d.get<String>(
      url,
      options: Options(
        headers: <String, String>{
          ...pan115PlayHeaders(cookie),
          'accept': 'application/json, text/plain, */*',
        },
      ),
    );
    final body = (res.data ?? '').trim();
    // 日志只落状态码与字节数：cookie 在请求头里，一个字都不能出现
    HubLogger.d('115 列目录 <- status=${res.statusCode} len=${body.length}');
    if (body.isEmpty) {
      return const Pan115Listing(ok: false, message: '115 返回空响应（可能已掉线）');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      // 风控页/网关错误页是 HTML，不是 JSON
      return const Pan115Listing(
        ok: false,
        message: '115 返回了非 JSON 内容（可能触发风控，请稍后重试）',
      );
    }
    return parsePan115FileList(decoded);
  } on DioException catch (e) {
    HubLogger.w(
      '115 列目录失败 path=${Uri.parse(url).path} '
      'status=${e.response?.statusCode} type=${e.type.name}',
    );
    return Pan115Listing(ok: false, message: _listingNetMessage(e));
  } catch (e) {
    // 同 playlink：兜底分支的异常类型不受控，不把 `$e` 拼进 UI 文案
    HubLogger.w('115 列目录异常 path=${Uri.parse(url).path}', e);
    return Pan115Listing(ok: false, message: '列目录失败（${e.runtimeType}）');
  }
}

/// 网络异常 → 人话（不含请求头/凭证）
String _listingNetMessage(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.sendTimeout:
      return '列目录超时，请检查网络或代理设置';
    case DioExceptionType.connectionError:
      return '无法连接 115 服务，请检查网络或代理设置';
    case DioExceptionType.badResponse:
      return '115 拒绝了列目录请求（status=${e.response?.statusCode ?? '-'}）';
    default:
      return '列目录失败（${e.type.name}）';
  }
}
