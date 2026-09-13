import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/util/logger.dart';

/// 115 扫码登录状态机
/// 【红线】凭证只留内存，绝不落盘 / 落库 / 打印。
enum SessionPhase {
  idle('未登录'),
  fetchingQr('正在获取二维码'),
  waitingScan('等待扫码'),
  scanned('已扫码，请在手机确认'),
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
  });

  final SessionPhase phase;
  final String qrUrl;
  final String uid;
  final String message;

  /// 仅内存持有的会话标识
  final String cookie;
  final int waitSeconds;

  bool get isLoggedIn => phase == SessionPhase.loggedIn;

  SessionState copyWith({
    SessionPhase? phase,
    String? qrUrl,
    String? uid,
    String? message,
    String? cookie,
    int? waitSeconds,
  }) =>
      SessionState(
        phase: phase ?? this.phase,
        qrUrl: qrUrl ?? this.qrUrl,
        uid: uid ?? this.uid,
        message: message ?? this.message,
        cookie: cookie ?? this.cookie,
        waitSeconds: waitSeconds ?? this.waitSeconds,
      );
}

/// 115 扫码登录控制器
/// 真实流程：取 token → 展示二维码 → 轮询状态（未扫码/已扫码/已确认）
/// 任一步失败都给出明确错误，**绝不伪造登录成功**。
class SessionController extends Notifier<SessionState> {
  Timer? _timer;
  String _proxy = '';
  static const int _qrBudgetSeconds = 180;

  @override
  SessionState build() => const SessionState();

  void configure({required String proxy}) => _proxy = proxy;

  Dio _dio() {
    final d = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
      responseType: ResponseType.plain,
      followRedirects: true,
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
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'referer': 'https://115.com/',
        'accept': 'application/json, text/plain, */*',
      };

  /// 去掉可能的 JSONP 外壳
  Map<String, dynamic> _parseJson(String body) {
    var s = body.trim();
    final i = s.indexOf('(');
    final j = s.lastIndexOf(')');
    if (i > 0 && j > i && s.startsWith(RegExp(r'[A-Za-z_$]'))) {
      s = s.substring(i + 1, j).trim();
    }
    return jsonDecode(s) as Map<String, dynamic>;
  }

  /// 发起真实扫码登录
  Future<void> start() async {
    _timer?.cancel();
    state = state.copyWith(
        phase: SessionPhase.fetchingQr, message: '', qrUrl: '', waitSeconds: 0);
    try {
      final res = await _dio().get<String>(
        'https://qrcodeapi.115.com/api/1.0/web/1.0/token/'
        '?_=${DateTime.now().millisecondsSinceEpoch}',
        options: Options(headers: _headers),
      );
      final json = _parseJson(res.data ?? '{}');
      final data = (json['data'] as Map?) ?? const <String, dynamic>{};
      final uid = data['uid']?.toString() ?? '';
      final sign = data['sign']?.toString() ?? '';
      final time = data['time']?.toString() ?? '';
      if (uid.isEmpty) {
        state = state.copyWith(
            phase: SessionPhase.failed,
            message: '未能获取二维码标识：${res.data?.toString().substring(0, 60) ?? '空响应'}');
        return;
      }
      // 二维码图片地址（115 官方接口，需带 Referer）
      final qr =
          'https://qrcodeapi.115.com/api/1.0/web/1.0/qrcode/?uid=$uid&sign=$sign&time=$time';
      state = state.copyWith(
        phase: SessionPhase.waitingScan,
        qrUrl: qr,
        uid: uid,
        message: '请使用 115 App 扫码',
      );
      _poll(uid, sign, time);
    } catch (e) {
      HubLogger.e('获取 115 二维码失败', e);
      state = state.copyWith(
          phase: SessionPhase.failed, message: '获取二维码失败：$e');
    }
  }

  void _poll(String uid, String sign, String time) {
    var waited = 0;
    _timer = Timer.periodic(const Duration(seconds: 2), (t) async {
      waited += 2;
      if (waited > _qrBudgetSeconds) {
        t.cancel();
        state = state.copyWith(phase: SessionPhase.expired, message: '二维码已超时失效');
        return;
      }
      try {
        final res = await _dio().get<String>(
          'https://qrcodeapi.115.com/api/1.0/web/1.0/status/'
          '?uid=$uid&sign=$sign&time=$time&_=${DateTime.now().millisecondsSinceEpoch}',
          options: Options(headers: _headers),
        );
        final json = _parseJson(res.data ?? '{}');
        final data = (json['data'] as Map?) ?? const <String, dynamic>{};
        final status = (data['status'] is num)
            ? (data['status'] as num).round()
            : int.tryParse(data['status']?.toString() ?? '');
        switch (status) {
          case 0:
            state = state.copyWith(
                phase: SessionPhase.waitingScan,
                message: '请使用 115 App 扫码',
                waitSeconds: _qrBudgetSeconds - waited);
            break;
          case 1:
            state = state.copyWith(
                phase: SessionPhase.scanned,
                message: '已扫码，请在手机上确认登录',
                waitSeconds: _qrBudgetSeconds - waited);
            break;
          case 2:
            t.cancel();
            final cookie = data['cookie']?.toString() ?? '';
            state = state.copyWith(
              phase: SessionPhase.loggedIn,
              message: '登录成功（凭证仅内存持有）',
              cookie: cookie,
              waitSeconds: 0,
            );
            HubLogger.i('115 扫码登录成功（不落盘）');
            break;
          default:
            state = state.copyWith(
                phase: SessionPhase.failed,
                message: '未知状态：$status');
            t.cancel();
        }
      } catch (e) {
        // 网络抖动不立即判死，继续轮询直到超时
        HubLogger.w('轮询登录状态异常', e);
      }
    });
  }

  void logout() {
    _timer?.cancel();
    state = const SessionState();
  }

  void reset() {
    _timer?.cancel();
    state = const SessionState();
  }
}

final sessionProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);
