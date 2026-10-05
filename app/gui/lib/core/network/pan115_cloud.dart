import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../db/repos.dart';
import '../util/logger.dart';
import 'pan115_tasks.dart';

/// 115 离线任务列表客户端（W3）
///
/// 【红线】Cookie 只从内存会话取用；日志只落「条数 / state」，**绝不打印凭证**。
class Pan115CloudService {
  const Pan115CloudService();

  static const String _endpoint =
      'https://115.com/web/lixian/?ct=lixian&ac=task_lists';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 拉取一页云端任务。任何异常都收敛为 `ok=false` 的结果对象，不向上抛，
  /// 避免「网络抖一下把看板刷成报错页」。
  Future<Pan115TaskPage> fetch({
    required String cookie,
    String proxy = '',
    int page = 1,
    int timeoutMs = 10000,
  }) async {
    if (cookie.isEmpty) {
      return const Pan115TaskPage(ok: false, message: '未登录 115，无法读取云端进度');
    }

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
        '$_endpoint&page=$page&_=${DateTime.now().millisecondsSinceEpoch}',
        options: Options(
          headers: <String, String>{
            'user-agent': _ua,
            'referer': 'https://115.com/',
            'cookie': cookie,
            'accept': 'application/json, text/plain, */*',
          },
        ),
      );
      final body = (res.data ?? '').trim();
      if (body.isEmpty) {
        return const Pan115TaskPage(
          ok: false,
          message: '115 返回空响应（可能已掉线，请重新登录）',
        );
      }
      final result = parsePan115TaskPage(jsonDecode(body));
      HubLogger.d(
        '115 云端任务 <- ok=${result.ok} '
        'n=${result.tasks.length} ${result.message}',
      );
      return result;
    } catch (e) {
      HubLogger.w('115 云端任务列表拉取失败', e);
      return Pan115TaskPage(ok: false, message: '拉取失败：$e');
    }
  }
}

/// 拉取云端任务并回填本地看板，返回一句人话结论供 UI 如实展示。
///
/// 概览页与导入页共用同一入口，避免两处逻辑漂移。
Future<String> syncCloudToRepo(
  ImportRepo repo, {
  required String cookie,
  String proxy = '',
  int timeoutMs = 10000,
}) async {
  final res = await const Pan115CloudService().fetch(
    cookie: cookie,
    proxy: proxy,
    timeoutMs: timeoutMs,
  );
  if (!res.ok) return '云端进度读取失败：${res.message}';
  if (res.tasks.isEmpty) return '云端暂无任务';
  final n = repo.syncCloud(res.tasks);
  return '云端任务 ${res.tasks.length} 条 · 回填 $n 条真实进度';
}
