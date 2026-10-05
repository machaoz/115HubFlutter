import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';

/// 带防盗链的远程图片加载（豆瓣 doubanio 图片无 Referer 直接 418/403）。
/// Flutter 的 Image.network 对跳转后的请求不一定带上 headers，因此这里用 dio
/// 自行把字节抓下来再交给 Image.memory，并做内存缓存避免重复请求。
class HubImageLoader {
  HubImageLoader._();

  static final Map<String, Uint8List> _cache = <String, Uint8List>{};
  static final Map<String, Future<Uint8List?>> _flying =
      <String, Future<Uint8List?>>{};

  static Dio _dio({String proxy = '', int timeoutMs = 10000}) {
    final d = Dio(
      BaseOptions(
        connectTimeout: Duration(milliseconds: timeoutMs),
        receiveTimeout: Duration(milliseconds: timeoutMs),
        responseType: ResponseType.bytes,
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
    return d;
  }

  /// 加载图片字节；失败返回 null（调用方负责降级占位）
  static Future<Uint8List?> load(
    String url, {
    String referer = '',
    String proxy = '',
  }) {
    if (url.isEmpty) return Future<Uint8List?>.value(null);
    final hit = _cache[url];
    if (hit != null) return Future<Uint8List?>.value(hit);
    final flying = _flying[url];
    if (flying != null) return flying;

    final future = _doLoad(url, referer: referer, proxy: proxy);
    _flying[url] = future;
    return future;
  }

  static Future<Uint8List?> _doLoad(
    String url, {
    required String referer,
    required String proxy,
  }) async {
    try {
      final res = await _dio(proxy: proxy).get<List<int>>(
        url,
        options: Options(
          headers: <String, String>{
            'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
            if (referer.isNotEmpty) 'referer': referer,
            'accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
          },
        ),
      );
      final data = res.data;
      if (data == null || data.isEmpty) return null;
      final bytes = Uint8List.fromList(data);
      _cache[url] = bytes;
      return bytes;
    } catch (_) {
      return null;
    } finally {
      _flying.remove(url);
    }
  }
}

/// 防盗链图片控件：加载中用骨架，失败用渐变占位（**不再出现黑边/默认图标**）
class RefererImage extends StatefulWidget {
  const RefererImage({
    super.key,
    required this.url,
    this.referer = '',
    this.proxy = '',
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  final String url;
  final String referer;
  final String proxy;
  final BoxFit fit;
  final Widget? placeholder;

  @override
  State<RefererImage> createState() => _RefererImageState();
}

class _RefererImageState extends State<RefererImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RefererImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.proxy != widget.proxy) {
      setState(() {
        _bytes = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final b = await HubImageLoader.load(
      widget.url,
      referer: widget.referer,
      proxy: widget.proxy,
    );
    if (!mounted) return;
    setState(() {
      _bytes = b;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: widget.fit, gaplessPlayback: true);
    }
    if (widget.placeholder != null) return widget.placeholder!;
    // 占位用品牌渐变，无描边、无黑底
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0x33FF7A2F), Color(0x2234E3D0)],
        ),
      ),
    );
  }
}
