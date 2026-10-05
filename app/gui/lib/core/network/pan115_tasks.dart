/// 115 离线任务（云下载）列表的**零 IO 解析层**（W3）
///
/// 设计对齐 `qr_status.dart`：只依赖 `dart:convert`，不碰 Flutter / dio，
/// 因此本机 `flutter_tester` 被安全策略拦截时，仍可用纯 Dart VM 直接跑断言
/// （见 `.tools/pan115_task_check.dart` 与 `test/pan115_task_test.dart`）。
///
/// 接口取证（2026-09）：
///   `GET https://115.com/web/lixian/?ct=lixian&ac=task_lists&page=1`（需会话 Cookie）
///   返回 `{state, page, pagecount, total, count, tasks:[{name, info_hash, size,
///   status, percentDone, ...}]}`
/// 社区实现交叉印证：python 版 115 离线脚本、115-offline-helper 用户脚本均以
/// `tasks[].percentDone` 作为进度、`tasks[].info_hash` 作为任务标识。
library;

/// 115 离线任务状态码真值表。
///
/// 0 = 排队/等待下载；1 = 下载中；2 = 下载完成（已转移进网盘）。
/// 其余取值一律不猜测语义，UI 侧按「状态N」原样透出，避免出现虚假进度。
const Map<int, String> kPan115TaskStatus = <int, String>{
  0: '排队中',
  1: '下载中',
  2: '已完成',
};

/// 一条 115 云端任务
class Pan115CloudTask {
  const Pan115CloudTask({
    required this.name,
    required this.infoHash,
    required this.sizeBytes,
    required this.percent,
    required this.statusCode,
    this.statusLabel = '',
  });

  /// 资源名（115 侧的任务名，即本地看板要展示的「实际资源名」）
  final String name;

  /// info hash（小写）；本地任务用它做匹配主键
  final String infoHash;

  final int sizeBytes;

  /// 进度百分比 0..100
  final double percent;

  final int statusCode;

  /// 状态中文标签（未知码回落为「状态N」）
  final String statusLabel;

  /// 是否已完成：状态码 2，或进度已到 99.5% 以上（服务端偶发不置终态）
  bool get finished => statusCode == 2 || percent >= 99.5;

  /// 是否仍在下载/排队
  bool get running => !finished;

  @override
  String toString() =>
      'Pan115CloudTask($name, hash=$infoHash, $percent%, $statusLabel)';
}

/// 一次云端列表查询的结果：区分「拉取失败」与「确实没有任务」
class Pan115TaskPage {
  const Pan115TaskPage({
    required this.ok,
    this.tasks = const <Pan115CloudTask>[],
    this.message = '',
  });

  final bool ok;
  final List<Pan115CloudTask> tasks;
  final String message;

  @override
  String toString() =>
      'Pan115TaskPage(ok=$ok, n=${tasks.length}, msg=$message)';
}

double? _asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v == null) return null;
  return double.tryParse(v.toString().trim());
}

/// 纯函数：从 115 `ac=task_lists` 的响应体解析任务列表。
///
/// `percentDone` 的标度在新旧接口间不一致（0..1 分数 vs 0..100 百分数）。
/// 这里做**整包级**标度判定：整包非零值都 ≤ 1 视为分数，否则视为百分数。
/// 之所以不逐条判断，是因为「1%」与「100%」在逐条口径下无法区分。
List<Pan115CloudTask> parsePan115Tasks(Object? decoded) {
  if (decoded is! Map) return const <Pan115CloudTask>[];
  final raw = decoded['tasks'];
  if (raw is! List) return const <Pan115CloudTask>[];

  final maps = raw.whereType<Map>().toList();
  if (maps.isEmpty) return const <Pan115CloudTask>[];

  final positive = maps
      .map((m) => _asDouble(m['percentDone'] ?? m['percent'] ?? m['progress']))
      .whereType<double>()
      .where((v) => v > 0)
      .toList();
  final asFraction = positive.isNotEmpty && positive.every((v) => v <= 1.0);

  final out = <Pan115CloudTask>[];
  for (final m in maps) {
    final name = (m['name'] ?? m['title'] ?? m['file_name'] ?? '')
        .toString()
        .trim();
    final hash = (m['info_hash'] ?? m['infoHash'] ?? m['hash'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final status = (_asDouble(m['status']) ?? 0).round();
    final size = (_asDouble(m['size'] ?? m['file_size']) ?? 0).round();

    var pct = _asDouble(m['percentDone'] ?? m['percent'] ?? m['progress']) ?? 0;
    if (asFraction) pct *= 100;
    if (status == 2 && pct < 100) pct = 100;

    out.add(
      Pan115CloudTask(
        name: name,
        infoHash: hash,
        sizeBytes: size,
        percent: pct.clamp(0, 100).toDouble(),
        statusCode: status,
        statusLabel: kPan115TaskStatus[status] ?? '状态$status',
      ),
    );
  }
  return out;
}

/// 纯函数：解析整页响应，附带 `state` 判定。
///
/// `state=false` 说明 115 拒绝了请求（最典型的原因是会话凭证已失效），
/// 必须与「列表为空」区分开 —— 否则 UI 会把「掉线」显示成「没有任务」。
Pan115TaskPage parsePan115TaskPage(Object? decoded) {
  if (decoded is! Map) {
    return const Pan115TaskPage(ok: false, message: '115 返回了非预期的数据结构');
  }
  final state = decoded['state'];
  final ok = state == null || state == true || state == 1;
  final tasks = parsePan115Tasks(decoded);
  if (ok) return Pan115TaskPage(ok: true, tasks: tasks);

  final msg =
      (decoded['error'] ?? decoded['message'] ?? decoded['errmsg'] ?? '')
          .toString()
          .trim();
  return Pan115TaskPage(
    ok: false,
    tasks: tasks,
    message: msg.isEmpty ? '115 拒绝了请求（会话可能已失效，请重新登录）' : msg,
  );
}

/// 本地任务 ↔ 云端任务的匹配（纯函数，便于单测）
///
/// 优先级：
///  1. `info_hash` 精确命中（本地已记录 remote_id，或 magnet 链接内含 hash）
///  2. 标题互含（115 侧任务名通常为资源名，但可能被截断/补后缀）
///
/// 返回 null 表示没有找到对应云端任务。
Pan115CloudTask? matchCloudTask(
  List<Pan115CloudTask> tasks, {
  required String remoteId,
  required String target,
  required String title,
}) {
  final rid = remoteId.trim().toLowerCase();
  final tgt = target.toLowerCase();
  final ttl = title.trim().toLowerCase();

  for (final t in tasks) {
    if (t.infoHash.isEmpty) continue;
    if (rid.isNotEmpty && rid == t.infoHash) return t;
    if (tgt.contains(t.infoHash)) return t;
  }
  if (ttl.isEmpty) return null;
  for (final t in tasks) {
    if (t.name.isEmpty) continue;
    final n = t.name.toLowerCase();
    if (n == ttl || n.contains(ttl) || ttl.contains(n)) return t;
  }
  return null;
}
