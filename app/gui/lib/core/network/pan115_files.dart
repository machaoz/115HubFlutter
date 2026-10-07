/// 115 网盘目录列表的**零 IO 解析层**（B1-4 / P 批次）
///
/// 设计对齐 `pan115_tasks.dart`：只依赖 `dart:core`，不碰 dio / dart:io / Flutter，
/// 因此本机 `flutter_tester` 被安全策略拦住时，仍可用纯 Dart VM 直接跑断言
/// （见 `.tools/pan115_files_check.dart` 与 `test/pan115_files_test.dart`）。
///
/// 接口取证（`docs/Spike-B1-S7-115网盘直链可行性.md` §2 Q1/Q6，2026-10 实测）：
///   `GET https://aps.115.com/natsort/files.php?cid=<dir>`（需会话 Cookie）
///   目录条目 `{cid, n, ...}`；文件条目 `{fid, n, s, pc, ico, iv, play_long, ...}`
///
/// 【为什么容错两种 data 形态】同一个 115 接口在不同版本/不同 cid 下返回过
/// `data:[...]`（直接条目数组）与 `data:{list:[...], count:..}`（包一层对象）两种形态。
/// 只认一种会让「换个目录就空列表」这类问题变成玄学，所以这里两种都吃。
library;

/// 视频扩展名白名单（小写比较）。
///
/// 用途：`iv` 字段缺失时（115 对部分老文件不吐 `iv`）用它兜底判定是否视频；
/// 同时暴露给 UI，保证「列表里哪些能播」与播放器真正能吃的格式是同一份真值表，
/// 不出现「列表显示能播、点开播不了」。
const Set<String> kPan115VideoExt = <String>{
  'mp4',
  'mkv',
  'avi',
  'mov',
  'wmv',
  'flv',
  'ts',
  'm2ts',
  'm4v',
  'webm',
  'rmvb',
  'rm',
  'mpg',
  'mpeg',
  '3gp',
  'ogv',
  'vob',
  'mts',
  'divx',
};

/// 115 列目录接口在「当前登录渠道没权限」时的错误码（spike 实测：现有 cookie
/// 通 `aps.115.com` 但通不了 `webapi.115.com`，即鉴权是**分域**的）。
const int kPan115ErrNoNoPermission = 990001;

/// 扩展名是否属于视频白名单（大小写不敏感）
bool isPan115VideoExt(String ext) {
  final e = ext.trim().toLowerCase();
  if (e.isEmpty) return false;
  return kPan115VideoExt.contains(e);
}

/// 从文件名取扩展名（小写，不含点；无扩展名返回空串）
String pan115ExtOfName(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return '';
  return name.substring(i + 1).trim().toLowerCase();
}

/// 115 网盘里的一个条目（目录或文件）
class Pan115Node {
  const Pan115Node({
    required this.fid,
    required this.name,
    this.pickcode = '',
    this.sizeBytes = 0,
    this.isDir = false,
    this.isVideo = false,
    this.playLongSec = 0,
    this.ico = '',
  });

  /// 115 的 id：文件取 `fid`，**目录取 `cid`**（调用方拿它继续往下钻）
  final String fid;

  final String name;

  /// 取直链用的 pickcode（目录恒为空）
  final String pickcode;

  final int sizeBytes;

  final bool isDir;

  /// 是否视频：`iv==1` 或扩展名命中白名单
  final bool isVideo;

  /// 时长（秒，`play_long`）；服务端没给就是 0，**绝不猜**
  final int playLongSec;

  /// 115 给的扩展名字段（小写原始值，可能是空）
  final String ico;

  /// 是否可发起取链（文件且拿到 pickcode）
  bool get canPlay => !isDir && pickcode.isNotEmpty;

  /// 展示用扩展名：`ico` 优先，缺失时回落到文件名后缀
  String get ext {
    final i = ico.trim().toLowerCase();
    return i.isNotEmpty ? i : pan115ExtOfName(name);
  }

  @override
  String toString() =>
      'Pan115Node(${isDir ? 'D' : 'F'} $name '
      'fid=$fid${pickcode.isEmpty ? '' : ' pc=$pickcode'}'
      '${isVideo ? ' video' : ''})';
}

/// 一次列目录的结果
///
/// 【为什么分离 ok 与 nodes 为空】`ok=false` 与「目录确实是空的」在 UI 上是两件事：
/// 前者要引导用户处理（掉线 / 没权限），后者只是空态。混在一起会把「被拒」
/// 显示成「这个目录没有文件」。
class Pan115Listing {
  const Pan115Listing({
    required this.ok,
    this.nodes = const <Pan115Node>[],
    this.message = '',
    this.count,
    this.total,
  });

  final bool ok;

  final List<Pan115Node> nodes;

  /// `ok=false` 时的原因（服务端文案或本地兜底文案），**绝不携带凭证**
  final String message;

  /// 服务端给的「本页/本级条目数」；没给就是 null（UI 不要当成 0 展示）
  final int? count;

  /// 服务端给的「总条目数」；没给就是 null
  final int? total;

  @override
  String toString() => 'Pan115Listing(ok=$ok, n=${nodes.length}, msg=$message)';
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// `state` 判定：缺失 / true / 1 都视为成功。
///
/// 115 的部分目录响应不带 `state` 字段（只有 `data`），所以缺失不能判失败。
bool _stateOk(Object? state) =>
    state == null || state == true || state == 1 || state == '1';

/// 从响应里挖出条目数组：`data` 为 List 直接吃；为 Map 时探测常见键名。
///
/// 探测键名的顺序即优先级；`data` 里再嵌一层 `data` 也一并兜住
///（115 的历史版本出现过 `data.data.list`）。
List<Object?> _rowsOf(Object? decoded) {
  if (decoded is List) return decoded;
  if (decoded is! Map) return const <Object?>[];
  final data = decoded['data'];
  if (data is List) return data;
  if (data is Map) {
    for (final key in const <String>['list', 'files', 'items', 'data']) {
      final v = data[key];
      if (v is List) return v;
    }
    return const <Object?>[];
  }
  // `data` 缺失/为字符串/为 null：多数情况是空目录，只有显式 state=false 才算错误
  return const <Object?>[];
}

bool _isDirEntry(Map m) {
  final cid = (m['cid'] ?? '').toString().trim();
  final fid = (m['fid'] ?? '').toString().trim();
  if (cid.isEmpty) return false;
  // 文件条目不带 cid；带 cid 且 fid 与 cid 相同时是目录（115 部分版本会两者都给）。
  // pickcode 只出现在文件上，有它一律按文件处理，避免把文件误判成目录。
  final pc = (m['pc'] ?? m['pickcode'] ?? '').toString().trim();
  if (pc.isNotEmpty) return false;
  return fid.isEmpty || fid == cid;
}

/// 纯函数：把条目数组解析成节点列表（**不排序**，供内部复用）
List<Pan115Node> parsePan115Nodes(Object? rows) {
  if (rows is! List) return const <Pan115Node>[];
  final out = <Pan115Node>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final name = (row['n'] ?? row['name'] ?? '').toString().trim();
    final cid = (row['cid'] ?? '').toString().trim();
    final fid = (row['fid'] ?? '').toString().trim();
    final isDir = _isDirEntry(row);
    final id = isDir ? cid : fid;
    // 既没有名字也没有 id 的条目没有任何展示/下钻价值，直接丢掉而不是塞个空行
    if (name.isEmpty && id.isEmpty) continue;

    final ico = (row['ico'] ?? '').toString().trim();
    final ext = ico.isNotEmpty ? ico.toLowerCase() : pan115ExtOfName(name);
    final iv = _asInt(row['iv']);
    // `iv` 是 115 自己判的视频标记，优先；缺失/为 0 时再用扩展名兜底
    final isVideo = !isDir && (iv == 1 || isPan115VideoExt(ext));

    out.add(
      Pan115Node(
        fid: isDir ? cid : fid,
        name: name,
        pickcode: isDir
            ? ''
            : (row['pc'] ?? row['pickcode'] ?? '').toString().trim(),
        sizeBytes: isDir ? 0 : (_asInt(row['s'] ?? row['size']) ?? 0),
        isDir: isDir,
        isVideo: isVideo,
        playLongSec: isDir ? 0 : (_asInt(row['play_long']) ?? 0),
        ico: ico,
      ),
    );
  }
  return out;
}

/// 排序：目录 → 视频文件 → 其他文件；同组内按名称（String.compareTo）。
///
/// 【为什么不按大小/时间】网盘浏览的主线动作是「找片子」，目录永远要先于文件，
/// 能播的文件要先于字幕/压缩包之类的附属文件；名称序是最可预期的次级序。
List<Pan115Node> _sortNodes(List<Pan115Node> nodes) {
  int rank(Pan115Node n) => n.isDir ? 0 : (n.isVideo ? 1 : 2);
  final sorted = List<Pan115Node>.of(nodes);
  sorted.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    return a.name.compareTo(b.name);
  });
  return sorted;
}

/// 纯函数：解析 `aps.115.com/natsort/files.php` 的整个响应。
///
/// 入参是**已 decode** 的对象；若上游 decode 失败把原始字符串丢进来（115 风控时
/// 会直接返回 HTML 错误页而不是 JSON），这里收敛成 `ok=false` 而不是抛异常 ——
/// 列目录失败不该把整页打崩。
Pan115Listing parsePan115FileList(Object? json) {
  if (json is! Map) {
    return const Pan115Listing(
      ok: false,
      message: '115 返回了无法解析的内容（可能触发了风控页，请稍后重试）',
    );
  }
  final rows = _rowsOf(json);
  final nodes = _sortNodes(parsePan115Nodes(rows));

  final data = json['data'];
  final int? count = _asInt(
    json['count'] ?? (data is Map ? data['count'] : null),
  );
  final int? total = _asInt(
    json['total'] ?? (data is Map ? data['total'] : null),
  );

  if (_stateOk(json['state'])) {
    return Pan115Listing(ok: true, nodes: nodes, count: count, total: total);
  }

  // state=false：服务端拒绝了请求
  final errNo = _asInt(json['errNo'] ?? json['errno'] ?? json['code']);
  final text =
      (json['error'] ?? json['errmsg'] ?? json['message'] ?? json['msg'] ?? '')
          .toString()
          .trim();

  // 990001 的服务端文案是「登录超时，请重新登录」，但实测根因是**登录渠道对应的
  // 鉴权域不通**（现有 cookie 通 aps.115.com、不通 webapi.115.com），
  // 照抄原文会让用户反复扫码却永远解决不了，所以这里覆盖成明确结论。
  if (errNo == kPan115ErrNoNoPermission) {
    return const Pan115Listing(ok: false, message: '当前会话无该接口权限（115 按登录渠道分域鉴权）');
  }
  final String message;
  if (errNo == null) {
    message = text.isEmpty ? '115 拒绝了列目录请求（未给出原因）' : text;
  } else if (text.isEmpty) {
    message = '115 拒绝了列目录请求（errNo=$errNo）';
  } else {
    message = '$text（errNo=$errNo）';
  }
  return Pan115Listing(ok: false, nodes: nodes, message: message);
}
