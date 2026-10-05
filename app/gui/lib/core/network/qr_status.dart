import 'dart:convert';

/// 115 扫码登录：二维码状态归类（**纯函数，零 IO，可单测**）
///
/// 协议出处与取证时间见本文档末尾「状态码真值表」。
///
/// 【最重要的一条设计原则】
/// **未知状态码一律不判终态。** 把一个可能仍然有效的二维码误判为失效，
/// 代价是本次登录彻底失败且用户完全无感；而保守等待的代价只是多等几秒，
/// 且外层还有二维码时间预算与换凭证重试兜底。两者代价完全不对等。
///
/// 历史事故（2026-09-16）：曾在此处用 `state == false` 去覆盖「失效」语义，
/// 结果服务端新增的 `code=90039`（message「请确认登录」= 已扫码待确认）
/// 被判成 expired —— 用户刚扫完码，客户端就自己把登录流程掐死了。
/// 此后第三方接口每次微调都会以同样方式击穿登录链路，
/// 因此把映射关系固化进 `test/session_classify_test.dart` 作为回归护栏。

/// 归一化后的内部状态
enum QrKind { waiting, scanned, confirmed, rejected, expired }

class QrStatus {
  const QrStatus(this.kind, [this.message = '']);

  final QrKind kind;

  /// 面向用户的提示文案；为空时由调用方填默认文案
  final String message;
}

/// 已知业务码（web 兼容端点 `/api/1.0/web/1.0/status/`）
const int qrCodeAwaitingScan = 90038; // message「请扫描二维码」
const int qrCodeAwaitingConfirm = 90039; // message「请确认登录」
const int qrCodeInvalid = 40199002; // 明确失效

int? _asInt(Object? v) =>
    v is num ? v.round() : int.tryParse(v?.toString() ?? '');

/// 把 115 的响应体归类成内部状态。入参应为**已解析过的 Map**（JSON 外壳由调用方剥）。
QrStatus classifyQrStatus(Map<String, dynamic> json) {
  final data = (json['data'] is Map)
      ? json['data'] as Map<String, dynamic>
      : const <String, dynamic>{};
  final msg = (json['message'] ?? json['error'] ?? '').toString().trim();

  // ── 1. 凭证到手即终态成功（少数口径会把 cookie 直接塞进 data）
  final cookie = data['cookie'];
  if (cookie is Map &&
      (cookie['UID']?.toString().isNotEmpty ?? false) &&
      (cookie['CID']?.toString().isNotEmpty ?? false)) {
    return const QrStatus(QrKind.confirmed);
  }

  // ── 2. data.status：官方长轮询 `/get/status/` 的权威口径
  //     0=未扫码 / 1=已扫码待确认 / 2=已确认 / -1=失效 / -2=拒绝
  final status = _asInt(data['status']);
  if (status != null) {
    switch (status) {
      case 2:
        return const QrStatus(QrKind.confirmed);
      case 1:
        return QrStatus(QrKind.scanned, msg.isEmpty ? '已扫码，请在手机上确认登录' : msg);
      case 0:
        return QrStatus(QrKind.waiting, msg);
      case -1:
        return QrStatus(QrKind.expired, msg.isEmpty ? '二维码已失效' : msg);
      case -2:
        return QrStatus(QrKind.rejected, msg.isEmpty ? '手机端已拒绝本次登录' : msg);
    }
    // 未知 status：透出文案继续等待，**绝不判终态**
    return QrStatus(QrKind.waiting, msg);
  }

  // ── 3. code：web 兼容端点的状态码序列
  final code = _asInt(json['code']);
  if (code != null) {
    switch (code) {
      case qrCodeAwaitingScan:
        return QrStatus(QrKind.waiting, msg.isEmpty ? '请使用 115 App 扫码' : msg);
      case qrCodeAwaitingConfirm:
        return QrStatus(QrKind.scanned, msg.isEmpty ? '已扫码，请在手机上确认登录' : msg);
      case qrCodeInvalid:
        return QrStatus(QrKind.expired, msg.isEmpty ? '二维码已失效' : msg);
    }
  }

  // ── 4. state：注意两个端点的 state **不是同一个东西**，必须按类型区分
  //     · `/get/status/`     → 数字：1=继续轮询，0=二维码无效（结束轮询）
  //     · `/web/1.0/status/` → 布尔：false 仅表示「本次业务未完成」
  //       用布尔 false 去判失效，正是 2026-09-16 那次事故的根因。
  final state = json['state'];
  if (state is num && state == 0) {
    return QrStatus(QrKind.expired, msg.isEmpty ? '二维码已失效' : msg);
  }

  // ── 5. 语义兜底：能读懂服务端文案时优先于机械的错误码
  if (msg.contains('拒绝') || msg.contains('取消')) {
    return QrStatus(QrKind.rejected, msg);
  }
  if (msg.contains('失效') || msg.contains('过期') || msg.contains('超时')) {
    return QrStatus(QrKind.expired, msg);
  }
  if (msg.contains('确认')) return QrStatus(QrKind.scanned, msg);

  // ── 6. 兜底：保守等待
  return QrStatus(QrKind.waiting, msg);
}

/// 去掉可能的 JSONP 外壳并解析为 Map。异常由调用方处理。
Map<String, dynamic> parseQrJsonBody(String body) {
  var s = body.trim();
  final i = s.indexOf('(');
  final j = s.lastIndexOf(')');
  if (i > 0 && j > i && s.startsWith(RegExp(r'[A-Za-z_$]'))) {
    s = s.substring(i + 1, j).trim();
  }
  final v = jsonDecode(s);
  return v is Map<String, dynamic> ? v : <String, dynamic>{'raw': v};
}

/// 状态码真值表（取证记录）
///
/// | 通道 | 响应 | 内部状态 | 首次取证 |
/// | --- | --- | --- | --- |
/// | web | `{"state":false,"code":90038,"message":"请扫描二维码"}` | waiting | 2026-09-16 |
/// | web | `{"state":false,"code":90039,"message":"请确认登录"}` | **scanned** | 2026-09-16（此前被误判 expired） |
/// | longpoll | `{"state":1,"code":0,"data":{"status":0}}` | waiting | 2026-09-16 |
/// | longpoll | `{"state":1,"code":0,"data":{"status":1}}` | scanned | 官方 OpenAPI 文档 |
/// | longpoll | `{"state":1,"code":0,"data":{"status":2}}` | confirmed | 官方 OpenAPI 文档 |
/// | longpoll | `{"state":1,"code":0,"data":{"status":-1}}` | expired | 官方 OpenAPI 文档 |
/// | longpoll | `{"state":1,"code":0,"data":{"status":-2}}` | rejected | 官方 OpenAPI 文档 |
/// | longpoll | `{"state":0,...}`（数字 0） | expired | 官方 OpenAPI 文档 |
/// | any | `{"state":false,"code":<未知>}` | **waiting**（不得判终态） | 2026-09-16 |
///
/// 官方口径旁证：https://www.yuque.com/115yun/open/shtpzfhewv5nag11
/// 实测补充：`/get/status/` 名义长轮询，实际服务端约 2s 超时回包。
/// 任何一行发生变化，都必须同步更新 `test/session_classify_test.dart`。
const String qrStatusSpecVersion = '2026-09-16';
