/// 源适配器返回的原始条目（对应 Electron 版 adapters/types.ts RawItem）
///
/// **刻意保持零依赖**：不引 dash Flutter、不引数据库、不引日志。
/// 这样协议解析层（`protocols.dart`）及其单元测试可以在纯 Dart VM 下直接运行，
/// 不必依赖 flutter_tester（本机被安全策略拦截时的兜底验证手段）。
class RawItem {
  const RawItem({
    required this.title,
    this.magnet,
    this.sha1,
    this.secLink,
    this.shareCode,
    this.receiveCode,
    this.sizeBytes,
    this.sizeText,
    this.fileCount,
    this.publishAt,
    this.hotness,
    this.detailUrl,
  });

  final String title;
  final String? magnet;
  final String? sha1;
  final String? secLink;
  final String? shareCode;
  final String? receiveCode;
  final int? sizeBytes;
  final String? sizeText;
  final int? fileCount;
  final int? publishAt;
  final double? hotness;
  final String? detailUrl;
}
