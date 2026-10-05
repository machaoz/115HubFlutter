import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/settings.dart';
import '../core/network/qr_status.dart';
import '../core/security/session_vault.dart';
import '../core/util/logger.dart';

/// 115 扫码登录状态机
///
/// 【红线】凭证只在「内存」与「系统加密存储（DPAPI）」之间流转：
/// 绝不落 SQLite / 普通文件 / 日志，也不进任何诊断输出。
/// 持久化由 `core/security/session_vault.dart` 独占（Windows = DPAPI，
/// macOS = Keychain，Linux = libsecret），**绝不自己另写一份**。
///
/// 协议来源：115 官方桌面登录脚本
///   `w.115.com/m_r/web/static/js/desktop_qr_login_service.js`
///   `cdnassets.115.com/login/login-api.js`
/// 真实流程（与官方逐字对齐）：
///   1. GET  {host}/api/1.0/web/1.0/token/            → {state,data:{uid,time,sign,qrcode}}
///   2. GET  `{host}/api/1.0/web/1.0/qrcode?qrfrom=1&uid=<uid>`   展示二维码（需 Referer: 115.com）
///   3. 轮询 {host}/api/1.0/web/1.0/status/（及官方 /get/status/）
///        data.status = 0 等待扫码 / 1 已扫码待确认 / 2 已确认 / -1 失效 / -2 拒绝
///   4. status==2 → POST passportapi.115.com/app/1.0/**{app}**/1.0/login/qrcode
///        `app={app}&account=uid&passwd=uid&country=CN&device_id=<32hex>&os=10.0&version=1.0`
///        → state 为真且 data.cookie 含 UID/CID/SEID 才算登录成功
///        `{app}` 即「绑定设备槽位」，见 `core/db/settings.dart` 的 kPan115Apps。
///        用 `web` 会顶掉用户浏览器网页端登录（V1.x 的老问题），默认改用 wechatmini。
/// 任一步失败都给出明确错误，**绝不伪造登录成功**。
enum SessionPhase {
  idle('未登录'),
  fetchingQr('正在获取二维码'),
  waitingScan('等待扫码'),
  scanned('已扫码，请确认'),
  loggedIn('已登录'),
  expired('二维码已失效'),
  failed('登录失败');

  const SessionPhase(this.label);
  final String label;
}

class SessionState {
  const SessionState({
    this.phase = SessionPhase.idle,
    this.qrUrl = '',
    this.uid = '',
    this.message = '',
    this.cookie = '',
    this.waitSeconds = 0,
    this.credentialPersisted = false,
    this.credentialRestored = false,
  });

  final SessionPhase phase;
  final String qrUrl;
  final String uid;
  final String message;

  /// 内存持有的会话凭证（UID/CID/SEID）
  ///
  /// 落库侧由 SessionVault 独占：只写系统加密存储（DPAPI），不写 SQLite / 文件 / 日志。
  final String cookie;

  /// 二维码剩余有效秒数（waitingScan / scanned 期间有意义）
  final int waitSeconds;

  /// 凭证已成功写入系统加密存储（下次启动可自动恢复）
  final bool credentialPersisted;

  /// 本次会话是冷启动时从系统加密存储（DPAPI）恢复来的
  final bool credentialRestored;

  bool get isLoggedIn => phase == SessionPhase.loggedIn;
  bool get isBusy => phase == SessionPhase.fetchingQr;

  SessionState copyWith({
    SessionPhase? phase,
    String? qrUrl,
    String? uid,
    String? message,
    String? cookie,
    int? waitSeconds,
    bool? credentialPersisted,
    bool? credentialRestored,
  }) => SessionState(
    phase: phase ?? this.phase,
    qrUrl: qrUrl ?? this.qrUrl,
    uid: uid ?? this.uid,
    message: message ?? this.message,
    cookie: cookie ?? this.cookie,
    waitSeconds: waitSeconds ?? this.waitSeconds,
    credentialPersisted: credentialPersisted ?? this.credentialPersisted,
    credentialRestored: credentialRestored ?? this.credentialRestored,
  );
}

/// 换凭证握手结果
enum _HsKind { ok, pending, expired, error }

class _Handshake {
  const _Handshake(this.kind, {this.detail = '', this.cookie = ''});

  final _HsKind kind;

  /// 诊断信息，**绝不携带任何凭证**
  final String detail;

  /// 成功时的凭证串 `UID=..; CID=..; SEID=..`
  /// （内存流转 + 由 SessionVault 写入系统加密存储（DPAPI），不进日志）
  final String cookie;
}

class SessionController extends Notifier<SessionState> {
  /// 115 侧二维码有效期约 120s（官方 JS：等待 > 12e4ms 即判失效）。
  /// 本地预算留冗余到 150s，最终以服务端返回的 -1 / 超时为准。
  static const int _qrBudgetSeconds = 150;

  /// 轮询间隔对齐官方桌面端实现（desktop_qr_login_service.js 为 500ms）。
  /// 旧的 1500ms 会让「手机上点确认 → 桌面端感知」出现肉眼可见的迟滞。
  static const Duration _pollInterval = Duration(milliseconds: 500);

  /// 判定二维码失效所需的连续一致次数（防单一错误码误杀）
  static const int _expireStreakThreshold = 2;
  static const String _qrHost = 'https://qrcodeapi.115.com';
  static const String _passportHost = 'https://passportapi.115.com';

  /// 绑定设备槽位（`app/1.0/{app}/1.0/login/qrcode` 的 `{app}` 段）。
  ///
  /// 【W1 关键】V1.x 把它写死成 `web`，于是软件一登录就把用户浏览器的网页端会话顶下线。
  /// 115 的会话按 app/设备类型分槽位，改用一个用户平时不占用的槽位（默认微信小程序）
  /// 即可与网页端并存、互不干扰。详见 `core/db/settings.dart` 的 kPan115Apps 取证说明。
  String _loginApp = kPan115DefaultApp;
  String _proxy = '';
  DateTime? _deadline;
  String _deviceId = '';

  /// 令牌/二维码镜像端点固定走 web（社区实测：这一步只取 token，不影响最终绑定的设备）
  static const String _tokenApi = '$_qrHost/api/1.0/web/1.0/token/';
  static const String _qrcodeApi = '$_qrHost/api/1.0/web/1.0/qrcode';
  static const String _statusApi = '$_qrHost/api/1.0/web/1.0/status/';
  static const String _longStatusApi = '$_qrHost/get/status/';

  /// 换凭证 / SSO 校验端点**随设备槽位变化**——这是绑定设备真正生效的地方
  String get _loginApi => '$_passportHost/app/1.0/$_loginApp/1.0/login/qrcode';
  String get _ssoApi => '$_passportHost/app/1.0/$_loginApp/1.0/check/sso';

  /// 当前绑定设备（供 UI 展示）
  String get loginApp => _loginApp;

  /// 会话代次：start/logout/reset 自增，用于丢弃迟到响应
  int _gen = 0;

  /// 已进入「确认后换凭证」阶段：两条轮询通道都要停下来，避免重复提交登录
  bool _completing = false;

  /// 上一次落地的原始状态码，用于抑制重复日志（长轮询会反复回到中间态）
  QrKind? _lastKind;

  /// 快轮询降噪：记录上一次打过日志的 (状态, 文案)
  QrKind? _lastPollKind;
  String _lastPollMsg = '';

  /// 换凭证握手协程已在跑（全局只允许一条）
  bool _hsRunning = false;

  /// 已观测到「扫码/确认」，进入主动换凭证阶段：
  /// 1) UI 不再被 scanning/waiting 中间态回退覆盖；2) 握手重试间隔缩短
  bool _exchanging = false;

  Timer? _timer;

  @override
  SessionState build() {
    ref.onDispose(() => _timer?.cancel());
    // 冷启动异步尝试恢复凭证：凭证库不可用 / 无凭证 / 凭证残缺都只是回到未登录，
    // **绝不阻塞界面**（恢复是 fire-and-forget，UI 先按未登录渲染）
    unawaited(_restoreFromVault());
    return const SessionState();
  }

  /// 从系统加密存储（DPAPI）恢复上次登录
  ///
  /// 校验口径：cookie 必须同时含非空 UID / CID / SEID（`isValidPan115Cookie`），
  /// 少一个都不算登录成功 —— 宁可让用户重新扫码，也不带半截凭证去请求 115。
  Future<void> _restoreFromVault() async {
    final cred = await ref.read(sessionVaultProvider).restore();
    if (cred == null || !ref.mounted) return;
    if (state.phase != SessionPhase.idle) return; // 用户已经手动发起登录了
    if (!isValidPan115Cookie(cred.cookie)) return;
    if (cred.loginApp.isNotEmpty) {
      _loginApp = normalizePan115App(cred.loginApp);
    }
    state = SessionState(
      phase: SessionPhase.loggedIn,
      uid: cred.uid,
      cookie: cred.cookie,
      message: '已从系统加密存储恢复登录（不写数据库 / 不写日志）',
      credentialPersisted: true,
      credentialRestored: true,
    );
    HubLogger.i('115 会话已从系统加密存储（DPAPI）恢复（凭证不写数据库 / 不写日志）');
  }

  /// 配置代理与绑定设备槽位（代理来自「设置 - 搜索与网络」，设备来自「设置 - 115 会话」）
  void configure({required String proxy, String? loginApp}) {
    _proxy = proxy;
    if (loginApp != null && loginApp.isNotEmpty) {
      _loginApp = normalizePan115App(loginApp);
    }
  }

  Dio _dio() {
    final d = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 12),
        responseType: ResponseType.plain,
        followRedirects: true,
      ),
    );
    if (_proxy.isNotEmpty) {
      d.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          c.findProxy = (uri) => 'PROXY $_proxy';
          return c;
        },
      );
    }
    return d;
  }

  Map<String, String> get _headers => <String, String>{
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'referer': 'https://115.com/',
    'accept': 'application/json, text/plain, */*',
  };

  /// 去掉可能的 JSONP 外壳（实现下沉到 qr_status.dart，单一来源）
  Map<String, dynamic> _parseJson(String body) => parseQrJsonBody(body);

  static String _brief(String? body, [int max = 120]) {
    final s = (body ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return '空响应';
    return s.length > max ? '${s.substring(0, max)}…' : s;
  }

  static String _netMsg(Object e) {
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return '网络超时，请在「设置 - 搜索与网络」检查代理';
        case DioExceptionType.connectionError:
          return '无法连接 115 服务，请检查网络或代理';
        default:
          return e.message ?? '$e';
      }
    }
    return '$e';
  }

  /// 生成设备指纹（32 位 hex），供完成登录调用
  static String _randomHex(int bytes) {
    final r = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  int _remainingSeconds() {
    final d = _deadline;
    if (d == null) return 0;
    final s = d.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  // ------------------------------------------------------------------ 对外

  /// 发起真实扫码登录
  Future<void> start() async {
    final myGen = ++_gen;
    _timer?.cancel();
    _deadline = null;
    _deviceId = _randomHex(16);
    state = const SessionState(
      phase: SessionPhase.fetchingQr,
      message: '正在获取二维码…',
    );
    HubLogger.i('115 login: request qrcode token (bindApp=$_loginApp)');

    try {
      final res = await _dio().get<String>(
        '$_tokenApi?_=${DateTime.now().millisecondsSinceEpoch}',
        options: Options(headers: _headers),
      );
      if (myGen != _gen) return;

      final json = _parseJson(res.data ?? '');
      final data = (json['data'] is Map)
          ? json['data'] as Map
          : const <String, dynamic>{};
      final uid = data['uid']?.toString() ?? '';
      final sign = data['sign']?.toString() ?? '';
      final time = data['time']?.toString() ?? '';
      if (uid.isEmpty || sign.isEmpty || time.isEmpty) {
        HubLogger.w('115 login: token missing fields');
        state = SessionState(
          phase: SessionPhase.failed,
          message: '未能获取二维码标识（服务端返回：${_brief(res.data)}）',
        );
        return;
      }
      HubLogger.i(
        '115 login: token ok, waiting scan (deadline=${_qrBudgetSeconds}s)',
      );

      // 官方二维码图片地址（qrfrom=1），必须带 Referer: https://115.com/
      final qr =
          '$_qrcodeApi?qrfrom=1&uid=$uid&_=${DateTime.now().millisecondsSinceEpoch}';
      _deadline = DateTime.now().add(const Duration(seconds: _qrBudgetSeconds));
      state = SessionState(
        phase: SessionPhase.waitingScan,
        qrUrl: qr,
        uid: uid,
        message: '请使用 115 App 扫码',
        waitSeconds: _qrBudgetSeconds,
      );
      _poll(myGen, uid, sign, time);
    } catch (e) {
      if (myGen != _gen) return;
      HubLogger.e('115 login: request token failed', e);
      state = SessionState(
        phase: SessionPhase.failed,
        message: '获取二维码失败：${_netMsg(e)}',
      );
    }
  }

  void logout() {
    HubLogger.i('115 logout');
    // 退出登录 = 连系统加密存储（DPAPI）一起清掉，下次启动不再自动恢复
    unawaited(ref.read(sessionVaultProvider).clear());
    _gen++;
    _completing = false;
    _lastKind = null;
    _lastPollKind = null;
    _lastPollMsg = '';
    _exchanging = false;
    _timer?.cancel();
    _deadline = null;
    state = const SessionState();
  }

  void reset() => logout();

  // ------------------------------------------------------------------ 轮询

  void _poll(int myGen, String uid, String sign, String time) {
    _completing = false;
    _lastKind = null;
    _lastPollKind = null;
    _lastPollMsg = '';
    _exchanging = false;
    var inflight = false;
    _timer = Timer.periodic(_pollInterval, (t) {
      if (inflight || myGen != _gen || _completing) return;
      inflight = true;
      _tick(myGen, uid, sign, time, t).whenComplete(() => inflight = false);
    });
    // 官方长轮询通道（与快轮询并行，谁先拿到确定性状态谁推进）
    unawaited(_longPoll(myGen, uid, sign, time));
    // 兜底：状态通道不健康（长轮询被网关掐、兼容端点不吐终态）时也要拉起握手，
    // 避免整个登录流程卡死在「等一个不来的事件」。
    // 取值依据：扫码动作通常发生在二维码展示后的 2-5 秒内，
    // 早先定在 10s 时曾出现过「状态通道先误判 expired 把流程掐死、兜底还没到点」
    // 的时序竞态（2026-09-16），因此提前到 3s。
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (myGen == _gen && !_completing) {
          HubLogger.i('115 handshake: fallback kick (status channel silent)');
          unawaited(_ensureHandshake(myGen, uid));
        }
      }),
    );
  }

  /// 官方长轮询：GET {host}/get/status/ 在「未扫码」期间**不回包**（实测挂起 > 20s），
  /// 一旦手机端扫码或点确认立即返回 —— 这是拿到 data.status=1/2 的可靠通道。
  ///
  /// 旧实现只按 500ms 打网页兼容端点，而兼容端点对桌面扫码 flow 会长期停在
  /// `{state:false,code:90038}`，于是「手机上点了确认，桌面端毫无反应」。
  Future<void> _longPoll(
    int myGen,
    String uid,
    String sign,
    String time,
  ) async {
    final q = 'uid=$uid&sign=$sign&time=$time';
    while (myGen == _gen && !_completing) {
      final left = _remainingSeconds();
      if (left <= 0) return;
      final startedAt = DateTime.now();
      String? raw;
      try {
        final res = await _dio().get<String>(
          '$_longStatusApi?$q'
          '&_=${DateTime.now().millisecondsSinceEpoch}',
          options: Options(
            headers: _headers,
            receiveTimeout: Duration(seconds: left.clamp(3, 180)),
          ),
        );
        if (myGen != _gen || _completing) return;
        raw = res.data;
        final body = (raw ?? '').trim();
        if (body.isEmpty) {
          HubLogger.d('115 longpoll <- empty body, keep waiting');
        } else {
          final st = classifyQrStatus(_parseJson(body));
          final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
          HubLogger.d(
            '115 longpoll <- ${st.kind.name} ${elapsed}ms '
            '${_brief(raw, 240)}',
          );
          if (myGen == _gen && !_completing) {
            await _applyStatus(myGen, uid, st, null);
          }
          if (myGen != _gen || _completing) return;

          // 只有终态才收手。中间态（waiting / **scanned**）必须继续挂着等下一个事件：
          // 曾在这里把 scanned 也当成收手信号直接 return，结果「扫码之后」只剩快轮询
          // 打网页兼容端点，而该端点在桌面扫码流程里拿不到 status=2 ——
          // 表现就是「手机上点了确认，桌面端 70 秒没反应」（CJ2-0001 复现）。
          final terminal =
              st.kind == QrKind.confirmed ||
              st.kind == QrKind.expired ||
              st.kind == QrKind.rejected;
          if (terminal) return;

          // 服务端对中间态可能秒回，加最小间隔避免把长轮询刷成忙循环
          if (elapsed < _pollInterval.inMilliseconds) {
            await Future<void>.delayed(
              _pollInterval - Duration(milliseconds: elapsed),
            );
          }
          continue;
        }
      } catch (e) {
        if (myGen != _gen || _completing) return;
        final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
        HubLogger.d('115 longpoll <- error ${elapsed}ms: ${_netMsg(e)}');
        HubLogger.w('115 长轮询中断，稍后重连', e);
      }
      if (myGen != _gen || _completing) return;
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  Future<void> _tick(
    int myGen,
    String uid,
    String sign,
    String time,
    Timer t,
  ) async {
    if (myGen != _gen) {
      t.cancel();
      return;
    }
    final left = _remainingSeconds();
    if (left <= 0) {
      t.cancel();
      state = state.copyWith(
        phase: SessionPhase.expired,
        message: '二维码已超时失效，请重新获取',
        waitSeconds: 0,
      );
      return;
    }
    try {
      final st = await _fetchStatus(uid, sign, time);
      if (myGen != _gen) return;
      await _applyStatus(myGen, uid, st, t);
    } catch (e) {
      if (myGen != _gen) return;
      // 网络抖动不立即判死，继续轮询直到预算耗尽
      HubLogger.w('轮询 115 登录状态异常', e);
      state = state.copyWith(
        phase: SessionPhase.waitingScan,
        message: '网络抖动，重试中…（剩余 $left s）',
        waitSeconds: left,
      );
    }
  }

  /// 状态落地（快轮询与长轮询共用同一出口）
  Future<void> _applyStatus(
    int myGen,
    String uid,
    QrStatus st,
    Timer? t,
  ) async {
    if (myGen != _gen) return;
    final prev = _lastKind;
    _lastKind = st.kind;
    final left = _remainingSeconds();

    // 进入换凭证阶段后，UI 不再被 waiting/scanned 中间态回退覆盖
    //（否则会出现「已确认，正在登录…」被刷回「请扫码」的抖动），
    // 但 expired / rejected 仍能推翻它。
    if (_exchanging &&
        (st.kind == QrKind.waiting || st.kind == QrKind.scanned)) {
      return;
    }

    switch (st.kind) {
      case QrKind.waiting:
        state = state.copyWith(
          phase: SessionPhase.waitingScan,
          message: st.message.isEmpty ? '请使用 115 App 扫码' : st.message,
          waitSeconds: left,
        );
        break;
      case QrKind.scanned:
        if (prev != QrKind.scanned) {
          HubLogger.i('115 login: qrcode scanned, waiting confirm');
        }
        if (!_exchanging) {
          _exchanging = true;
          unawaited(_ensureHandshake(myGen, uid));
        }
        state = state.copyWith(
          phase: SessionPhase.scanned,
          message: st.message.isEmpty ? '已扫码，请在手机上确认登录' : st.message,
          waitSeconds: left,
        );
        break;
      case QrKind.confirmed:
        if (!_exchanging) {
          _exchanging = true;
        }
        if (prev != QrKind.confirmed) {
          HubLogger.i('115 扫码已确认，正在换取会话凭证');
          state = state.copyWith(
            phase: SessionPhase.scanned,
            message: '已确认，正在完成登录…',
            waitSeconds: 0,
          );
        }
        unawaited(_ensureHandshake(myGen, uid));
        break;
      case QrKind.rejected:
        t?.cancel();
        _completing = true; // 终态：握手协程也一并收手
        HubLogger.w('115 login: rejected by client');
        state = state.copyWith(
          phase: SessionPhase.failed,
          message: st.message.isEmpty ? '手机端已拒绝本次登录' : st.message,
          waitSeconds: 0,
        );
        break;
      case QrKind.expired:
        t?.cancel();
        _completing = true; // 终态：握手协程也一并收手
        HubLogger.w('115 login: qrcode expired');
        state = state.copyWith(
          phase: SessionPhase.expired,
          message: st.message.isEmpty ? '二维码已失效' : st.message,
          waitSeconds: 0,
        );
        break;
    }
  }

  /// 快轮询状态接口：只用**即时返回**的网页兼容端点（实测 ~20ms 回包）。
  ///
  /// 官方 `/get/status/` 是长轮询（未扫码时不回包），由 `_longPoll` 单独负责；
  /// 若把它塞进这条 500ms 快通道，未扫码阶段会被活活挂住十几秒，反而更糟。
  Future<QrStatus> _fetchStatus(String uid, String sign, String time) async {
    final q =
        'uid=$uid&sign=$sign&time=$time'
        '&_=${DateTime.now().millisecondsSinceEpoch}';
    final url = '$_statusApi?$q';
    final startedAt = DateTime.now();
    final res = await _dio().get<String>(
      url,
      options: Options(
        headers: _headers,
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    final body = (res.data ?? '').trim();
    if (body.isEmpty) throw StateError('115 登录状态接口返回空: $url');
    final st = classifyQrStatus(_parseJson(body));
    // 降噪：快轮询每 500ms 一次，同状态每数百行刷屏会淹没真正的转折点。
    // 只在**状态发生变化**或**文案发生变化**时落一行完整的取证日志。
    if (st.kind != _lastPollKind || st.message != _lastPollMsg) {
      _lastPollKind = st.kind;
      _lastPollMsg = st.message;
      HubLogger.d(
        '115 fastpoll <- ${st.kind.name} '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms ${_brief(body, 240)}',
      );
    }
    return st;
  }

  // -------------------------------------------------- 换凭证握手（官方 complete()）

  /// 启动握手协程：幂等，全局只允许一条
  Future<void> _ensureHandshake(int myGen, String uid) async {
    if (_hsRunning || myGen != _gen) return;
    _hsRunning = true;
    HubLogger.i('115 handshake: start');
    try {
      await _handshakeLoop(myGen, uid);
    } finally {
      _hsRunning = false;
    }
  }

  /// 对齐官方 `DesktopQrLoginService.complete()`：
  ///
  /// 官方**并不等** status=2 —— 它直接 POST `login/qrcode`，该请求在服务端会阻塞到
  /// 用户在手机上点确认，返回 `{state:1, data:{cookie:{UID,CID,SEID}}}` 后再 GET
  /// `check/sso` 校验 `state===0 && data.user_id`。
  ///
  /// 旧实现死等 `/get/status/` 吐 status=2，而桌面扫码 flow 下这个值常常永远不来，
  /// 于是「手机上点了确认、桌面端 70 秒毫无反应」（CJ2-0001）。这里改为主动握手 + 重试。
  Future<void> _handshakeLoop(int myGen, String uid) async {
    var attempt = 0;
    var expireStreak = 0;
    while (myGen == _gen && !_completing) {
      if (_remainingSeconds() <= 0) return;
      attempt++;
      final r = await _handshake(uid);
      if (myGen != _gen || _completing) return;

      switch (r.kind) {
        case _HsKind.ok:
          _completing = true;
          final cookie = r.cookie;
          // 写系统加密存储（Windows DPAPI 密文，密钥由 OS 托管）。
          // 失败不能推翻登录本身：内存里的凭证是真的，只是下次要重新扫码。
          final persisted = await ref
              .read(sessionVaultProvider)
              .save(
                SessionCredential(
                  cookie: cookie,
                  uid: uid,
                  loginApp: _loginApp,
                ),
              );
          if (myGen != _gen) return;
          state = SessionState(
            phase: SessionPhase.loggedIn,
            qrUrl: state.qrUrl,
            uid: uid,
            message: persisted
                ? '登录成功（凭证已加密存入本机，不写数据库 / 日志）'
                : '登录成功，但凭证记忆失败：本次会话有效，重启后需重新扫码',
            cookie: cookie,
            waitSeconds: 0,
            credentialPersisted: persisted,
          );
          HubLogger.i(
            persisted
                ? '115 扫码登录成功（凭证已加密落盘，原文不写库 / 不写日志）'
                : '115 扫码登录成功，但凭证记忆失败（本次会话有效）',
          );
          return;
        case _HsKind.expired:
          // 交叉验证：单一错误码不允许掐死整条登录链路。
          // 曾有一次误判（code 语义漂移）就在扫码瞬间把流程杀掉，
          // 用户手机上的「确认」点了也没人来收。要求连续两次一致才判死。
          expireStreak++;
          if (expireStreak < _expireStreakThreshold) {
            HubLogger.w(
              '115 handshake: #$attempt 失效候选 ($expireStreak/'
              '$_expireStreakThreshold)，待交叉验证 — ${r.detail}',
            );
            break;
          }
          _completing = true;
          HubLogger.w(
            '115 handshake: qrcode invalid（连续 $expireStreak 次确认）'
            ' — ${r.detail}',
          );
          state = state.copyWith(
            phase: SessionPhase.expired,
            message: r.detail,
            waitSeconds: 0,
          );
          return;
        case _HsKind.pending:
          expireStreak = 0;
          HubLogger.d('115 handshake: #$attempt 尚未确认 — ${r.detail}');
          break;
        case _HsKind.error:
          expireStreak = 0;
          HubLogger.w('115 handshake: #$attempt 异常 — ${r.detail}');
          break;
      }
      // 已扫码/已确认 → 2s 快重试；未扫码（兜底探测）→ 10s 慢探测，别把二维码刷没
      await Future<void>.delayed(
        _exchanging ? const Duration(seconds: 2) : const Duration(seconds: 10),
      );
    }
  }

  /// 单次握手：POST 换凭证 → 成功后 GET check/sso 交叉确认
  Future<_Handshake> _handshake(String uid) async {
    final startedAt = DateTime.now();
    var raw = '';
    try {
      final res = await _dio().post<String>(
        _loginApi,
        data: <String, String>{
          // 【W1】app 必须与 URL 路径段一致：两者共同决定绑定的设备槽位。
          // 用 web 会顶掉浏览器网页端；默认改为 wechatmini（见 kPan115Apps）。
          'app': _loginApp,
          'account': uid,
          'passwd': uid,
          'country': 'CN',
          'device_id': _deviceId,
          'os': '10.0',
          'version': '1.0',
        },
        options: Options(
          headers: <String, String>{
            ..._headers,
            'content-type': 'application/x-www-form-urlencoded',
          },
          // 该请求可能长期挂起（服务端阻塞到用户点确认），超时给足但要有上限
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      raw = res.data ?? '';
      final json = _parseJson(raw);
      final data = (json['data'] is Map)
          ? json['data'] as Map
          : const <String, dynamic>{};
      final cookie = (data['cookie'] is Map)
          ? data['cookie'] as Map
          : const <String, dynamic>{};
      final u = cookie['UID']?.toString() ?? '';
      final c = cookie['CID']?.toString() ?? '';
      final se = cookie['SEID']?.toString() ?? '';
      final stateOk = json['state'] == true || json['state'] == 1;
      final code = json['code'];
      final msg = (json['message'] ?? json['error'] ?? '').toString().trim();

      // 只落凭证「有无」，绝不打印 UID/CID/SEID
      HubLogger.d(
        '115 handshake <- app=$_loginApp state=${json['state']} '
        'code=${code ?? '-'} '
        'uid=${u.isEmpty ? '空' : '有'} cid=${c.isEmpty ? '空' : '有'} '
        'seid=${se.isEmpty ? '空' : '有'} '
        '${DateTime.now().difference(startedAt).inMilliseconds}ms '
        '${_brief(raw, 200)}',
      );

      if (stateOk && u.isNotEmpty && c.isNotEmpty && se.isNotEmpty) {
        final sso = await _checkSso();
        HubLogger.i(
          '115 handshake: credential ok, '
          'sso=${sso == null ? 'unverified' : 'verified'}',
        );
        return _Handshake(_HsKind.ok, cookie: 'UID=$u; CID=$c; SEID=$se');
      }

      // 扫码之前（兜底探测阶段）服务端回什么都不能算「失效」——否则一次探测
      // 就可能把还没扫的二维码判死。只有观测到扫码/确认后才按错误码判失效。
      if (_exchanging && (_isExpiredCode(code) || _looksExpired(msg))) {
        return _Handshake(
          _HsKind.expired,
          detail: msg.isEmpty ? '二维码已失效，请重新获取' : msg,
        );
      }
      return _Handshake(
        _HsKind.pending,
        detail:
            'state=${json['state']} code=${code ?? '-'}'
            '${msg.isEmpty ? '' : ' $msg'}',
      );
    } catch (e) {
      HubLogger.d(
        '115 handshake <- error: ${_netMsg(e)} '
        '(${DateTime.now().difference(startedAt).inMilliseconds}ms) '
        '${_brief(raw, 160)}',
      );
      return _Handshake(_HsKind.error, detail: _netMsg(e));
    }
  }

  /// 官方 complete() 第二步。凭证本身已可用，SSO 仅作交叉确认，失败不影响登录。
  Future<String?> _checkSso() async {
    try {
      final res = await _dio().get<String>(
        '$_ssoApi?device_id=$_deviceId'
        '&_=${DateTime.now().millisecondsSinceEpoch}',
        options: Options(
          headers: _headers,
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final json = _parseJson(res.data ?? '');
      final data = (json['data'] is Map)
          ? json['data'] as Map
          : const <String, dynamic>{};
      final userId = data['user_id']?.toString() ?? '';
      // user_id 属账号标识，日志只记有无
      HubLogger.d(
        '115 sso <- state=${json['state']} '
        'userId=${userId.isEmpty ? '空' : '有'}',
      );
      if (json['state'] == 0 && userId.isNotEmpty) return userId;
      return null;
    } catch (e) {
      HubLogger.w('115 SSO 校验失败（不影响凭证）', e);
      return null;
    }
  }

  static bool _isExpiredCode(Object? code) {
    final n = code is num ? code.round() : int.tryParse(code?.toString() ?? '');
    return n == 40199002 || n == 40101025;
  }

  static bool _looksExpired(String msg) =>
      msg.contains('失效') ||
      msg.contains('过期') ||
      msg.contains('超时') ||
      msg.contains('已使用');
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
