import 'package:media_kit/media_kit.dart';

/// 播放源装配：全工程**唯一**允许构造带鉴权头 [Media] 的地方。
///
/// 【红线 · 为什么它是必经之门】
/// `Media` 的 `toString()` 会把 `httpHeaders` 原样拼进字符串
/// （见 media_kit 1.2.6 `lib/src/models/media/media_native.dart:214`：
/// `'Media($uri, extras: $extras, httpHeaders: $httpHeaders, ...)'`）。
/// 因此一旦给 [Media] 带上凭证（网盘直连用），任何 `print(media)` /
/// `toString()` / `jsonEncode` / 写日志或写库都会把 UID/CID/SEID **整个吐出来** ——
/// 直接击穿本项目既定的「凭证不写日志、不写数据库」红线。
///
/// 由此确立三条硬规矩，**后续接网盘源时必须继续遵守**：
/// 1. 禁止 `print(media)` / `media.toString()` / 任何插值到日志或 UI 文案；
/// 2. 禁止把 [Media]（含 `extras` / `httpHeaders`）序列化写库、写磁盘、写配置；
/// 3. 需要对外描述时，只能用 [describe] —— 它只暴露 URI 的 scheme/host，
///    不碰 header 一个字符。
///
/// 本地源（`file://`）目前用不到 `httpHeaders`，规矩现在先立起来，
/// 是为了网盘源接进来时不必返工。
class MediaSource {
  const MediaSource._();

  /// 构造播放源。`httpHeaders` 仅供网盘直连用，本地源不要传。
  static Media media(String uri, {Map<String, String>? httpHeaders}) {
    return Media(uri, httpHeaders: httpHeaders);
  }

  /// 日志/UI 可安全使用的描述。**只报 scheme/host，绝不输出 header 与完整 URI。**
  static String describe(Media media) {
    // 刻意不加 final：try / catch 两条路径都要赋值，final 局部变量只允许赋值一次。
    String scheme;
    String host;
    try {
      final u = Uri.parse(media.uri);
      scheme = u.scheme;
      host = u.host.isEmpty ? '-' : u.host;
    } catch (_) {
      scheme = 'unknown';
      host = '-';
    }
    // 本地源会被 media_kit 归一化：`file:///C:/x.mp4` → 裸路径 `C:/x.mp4`
    // （media_native.dart 的 normalizeURI，口径对齐 libmpv）。裸路径再喂给
    // Uri.parse 会把盘符 `C:` 误当成 scheme，日志里就成了 Media(scheme=c,...)。
    // 真实 URI scheme 最短为 2 字符（file / http / fd ...），单字符或空一律按本地文件还原。
    if (scheme.length <= 1) scheme = 'file';
    final bool hasHeaders = media.httpHeaders != null;
    // 只报"有无"，不报内容 —— 与 core/security/pan115_cookie.dart 的
    // describePan115Cookie() 同一口径。
    return 'Media(scheme=$scheme, host=$host, httpHeaders=${hasHeaders ? '有' : '无'})';
  }
}
