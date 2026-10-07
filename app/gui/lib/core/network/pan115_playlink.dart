import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../util/logger.dart';

/// 115 网盘**取直链**客户端（B1-4 / P 批次）
///
/// 【红线】Cookie 只从内存会话取用（`state/session.dart` 的 `SessionState.cookie`），
/// 绝不落库 / 落文件 / 落日志。日志只落「pickcode + 状态码」，
/// **绝不打 `RequestOptions.headers`** —— dio 的 headers 里带着 cookie，
/// 直接 `print(e)` 或打 `e.requestOptions` 就等于把凭证写进日志。
///
/// 【可行边界】见 `docs/Spike-B1-S7-115网盘直链可行性.md` §2：
/// `webapi.115.com` 对本项目现有（微信小游戏槽位）cookie 实测返回 `990001`。
/// 因此本文件的**正常结局很可能就是 ok=false**，UI 必须如实转述原因，
/// 不允许伪造一个可播地址。
/// 取直链端点：官方 Web 下载通道自己也在用（spike §2 Q1 从 `115.com/?ct=download`
/// 返回页的内联 JS 里取证），期望回 `file_url`。
const String kPan115DownloadApi = 'https://webapi.115.com/files/download';

/// 浏览器 UA：与 `pan115_cloud.dart` 同款，避免 115 按爬虫处理
const String kPan115Ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 115 全站校验 Referer，缺了会被拒
const String kPan115Referer = 'https://115.com/';

/// 播放/下载直链时必须随请求带上的头。
///
/// 【为什么要自带 UA】mpv 的 `http-header-fields` 是**替换**默认头而不是追加
/// （spike §2 Q2 已取证），不显式给 UA 就会以空 UA 发请求，容易被 115 判非法。
/// 因此三个头一个都不能省。
Map<String, String> pan115PlayHeaders(String cookie) => <String, String>{
  'Cookie': cookie,
  'User-Agent': kPan115Ua,
  'Referer': kPan115Referer,
};

/// 一次取直链的结果
class Pan115Link {
  const Pan115Link({
    required this.ok,
    this.url = '',
    this.message = '',
    this.statusCode,
  });

  final bool ok;

  /// 直链地址；`ok=false` 时恒为空（**绝不返回半个地址让上层去猜**）
  final String url;

  /// 失败原因（中文，可直接展示给用户），不含任何凭证
  final String message;

  /// HTTP 状态码；网络层就失败时为 null
  final int? statusCode;

  @override
  String toString() => 'Pan115Link(ok=$ok, status=${statusCode ?? '-'})';
}

/// 取一个文件的下载直链。
///
/// 任何异常都收敛为 `ok=false` 的结果对象，不向上抛 —— 取链是 UI 交互的中间步骤，
/// 一次网络抖动不该变成未捕获异常。
Future<Pan115Link> fetchPan115DownloadUrl({
  required String cookie,
  required String pickcode,
  String proxy = '',
  int timeoutMs = 10000,
}) async {
  if (cookie.isEmpty) {
    return const Pan115Link(ok: false, message: '未登录 115，无法取播放直链');
  }
  final pc = pickcode.trim();
  if (pc.isEmpty) {
    return const Pan115Link(ok: false, message: '这个文件没有 pickcode，无法取直链');
  }

  final url = '$kPan115DownloadApi?dl=1&pickcode=${Uri.encodeComponent(pc)}';
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
    final status = res.statusCode;
    // 只落 pickcode 与状态码：115 直链失败是高频排查项，但凭证一个字都不能出现
    HubLogger.d('115 取直链 <- pc=$pc status=$status len=${body.length}');
    if (body.isEmpty) {
      return Pan115Link(
        ok: false,
        message: '115 返回空响应（status=${status ?? '-'}）',
        statusCode: status,
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      // 风控/网关拦截时会返回 HTML 错误页，不是 JSON
      return Pan115Link(
        ok: false,
        message: '115 返回了非 JSON 内容（status=${status ?? '-'}，可能触发风控）',
        statusCode: status,
      );
    }
    if (decoded is! Map) {
      return Pan115Link(
        ok: false,
        message: '115 返回了非预期的数据结构（status=${status ?? '-'}）',
        statusCode: status,
      );
    }

    final state = decoded['state'];
    final ok = state == null || state == true || state == 1 || state == '1';
    final errNo = decoded['errNo'] ?? decoded['errno'] ?? decoded['code'];
    final fileUrl = _firstUrl(decoded);

    if (ok && fileUrl != null && fileUrl.isNotEmpty) {
      return Pan115Link(ok: true, url: fileUrl, statusCode: status);
    }

    // 990001：服务端文案是「登录超时，请重新登录」，但实测是**登录渠道的鉴权域
    // 不通**（现有 cookie 通 aps.115.com、不通 webapi.115.com）。
    // 照抄原文会让用户反复扫码，所以换成可行动的结论。
    final n = errNo is num
        ? errNo.round()
        : int.tryParse((errNo ?? '').toString().trim());
    if (n == 990001) {
      return Pan115Link(
        ok: false,
        message:
            '当前登录渠道的会话无 webapi 直链权限；'
            '可在网页端扫码登录后重试，或先用本地/下载路径播放',
        statusCode: status,
      );
    }

    final text =
        (decoded['error'] ??
                decoded['errmsg'] ??
                decoded['message'] ??
                decoded['msg'] ??
                '')
            .toString()
            .trim();
    return Pan115Link(
      ok: false,
      message: text.isEmpty ? '115 未返回直链（status=${status ?? '-'}）' : text,
      statusCode: status,
    );
  } on DioException catch (e) {
    // e.requestOptions.headers 里有 cookie，一律不打；只落 path 与状态码
    HubLogger.w(
      '115 取直链失败 pc=$pc '
      'path=${Uri.parse(url).path} status=${e.response?.statusCode} '
      'type=${e.type.name}',
    );
    return Pan115Link(
      ok: false,
      message: _netMessage(e),
      statusCode: e.response?.statusCode,
    );
  } catch (e) {
    // 注意：这里刻意不把 `$e` 拼进 UI 文案 —— 兜底分支的异常类型不受控，
    // 万一某个底层异常串里带了请求上下文，就会顺着 UI 文案泄出去。
    HubLogger.w('115 取直链异常 pc=$pc path=${Uri.parse(url).path}', e);
    return Pan115Link(ok: false, message: '取直链失败（${e.runtimeType}）');
  }
}

/// 从响应里挖直链：顶层 `file_url` 优先，其次 `data.file_url`（115 两个版本都出现过）
String? _firstUrl(Map<dynamic, dynamic> json) {
  for (final key in const <String>['file_url', 'url', 'download_url']) {
    final v = json[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  final data = json['data'];
  if (data is Map) {
    for (final key in const <String>['file_url', 'url', 'download_url']) {
      final v = data[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
  }
  return null;
}

/// 网络异常 → 人话。绝不包含请求头/凭证。
String _netMessage(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.sendTimeout:
      return '取直链超时，请检查网络或代理设置';
    case DioExceptionType.connectionError:
      return '无法连接 115 服务，请检查网络或代理设置';
    case DioExceptionType.badResponse:
      return '115 拒绝了取链请求（status=${e.response?.statusCode ?? '-'}）';
    default:
      return '取直链失败（${e.type.name}）';
  }
}
