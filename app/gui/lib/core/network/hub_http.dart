import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../db/settings.dart';

const List<String> kUserAgents = <String>[
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15',
];

/// 统一网络出口（对齐 Electron 版 http-client.ts 口径）
/// - 支持本机 HTTP 代理（PoC-3 验证目标：Clash 类代理）
/// - 按 host 令牌桶限流（默认 ≤1 req/s，符合 robots 友好策略）
/// - UA 轮转 / 固定，拟人化间隔
class HubHttp {
  HubHttp({required this.settings});

  NetworkSettings settings;
  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: Duration(milliseconds: settings.timeoutMs),
    receiveTimeout: Duration(milliseconds: settings.timeoutMs),
    responseType: ResponseType.plain,
    validateStatus: (s) => s != null && s < 500,
  ));

  /// host -> 下次可请求时间（令牌桶，简化为窗口间隔）
  final Map<String, DateTime> _nextAllowed = <String, DateTime>{};

  String get ua => settings.uaStrategy == UaStrategy.rotate
      ? kUserAgents[DateTime.now().millisecond % kUserAgents.length]
      : kUserAgents.first;

  Dio get client => _dio;

  /// 代理/UA/超时随设置动态生效
  void configure(NetworkSettings s) {
    settings = s;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final c = HttpClient();
          if (s.proxy.isNotEmpty) {
            c.findProxy = (uri) => 'PROXY ${s.proxy}';
            c.badCertificateCallback = (_, __, ___) => false;
          }
          return c;
        },
        validateCertificate: null,
      );
    }
    _dio.options.connectTimeout = Duration(milliseconds: s.timeoutMs);
    _dio.options.receiveTimeout = Duration(milliseconds: s.timeoutMs);
  }

  /// 按 host 限流等待（≤0 表示不限）
  Future<void> _throttle(String host) async {
    final rps = settings.rateLimitPerHost;
    if (rps <= 0) return;
    final now = DateTime.now();
    final next = _nextAllowed[host];
    if (next != null && now.isBefore(next)) {
      await Future<void>.delayed(next.difference(now));
    }
    _nextAllowed[host] =
        DateTime.now().add(Duration(milliseconds: (1000 / rps).round()));
  }

  /// 拟人化停顿（降低被风控概率，Electron 版口径 240–760ms）
  Future<void> humanize() async {
    if (!settings.humanize) return;
    final ms = 240 + DateTime.now().microsecond % 520;
    await Future<void>.delayed(Duration(milliseconds: ms));
  }

  Future<Response<T>> get<T>(
    String url, {
    Map<String, String>? headers,
    bool humanize = false,
    CancelToken? cancelToken,
  }) async {
    final uri = Uri.parse(url);
    await _throttle(uri.host);
    if (humanize) await this.humanize();
    return _dio.get<T>(
      url,
      options: Options(headers: <String, dynamic>{
        'user-agent': ua,
        'accept-language': 'zh-CN,zh;q=0.9',
        ...?headers,
      }),
      cancelToken: cancelToken,
    );
  }
}
