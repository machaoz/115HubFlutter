// 纯 Dart 复跑 test/pan115_task_test.dart 的全部断言。
// 用途：本机 flutter_tester 被安全策略拦住时，用 Dart VM 等价验证纯函数逻辑。
// 运行：cd app/gui && dart run .tools/pan115_task_check.dart
import '../lib/core/network/pan115_tasks.dart';

int _pass = 0;
int _fail = 0;

void checkEq(Object? actual, Object? expected, String label) {
  if ('$actual' == '$expected') {
    _pass++;
    print('  [ok]   $label -> $actual');
  } else {
    _fail++;
    print('  [FAIL] $label -> $actual，期望 $expected');
  }
}

void checkTrue(bool cond, String label) {
  if (cond) {
    _pass++;
    print('  [ok]   $label');
  } else {
    _fail++;
    print('  [FAIL] $label');
  }
}

/// 构造一条 115 task_lists 里的任务
Map<String, dynamic> task({
  String? name = '示例资源',
  String? hash = 'ABCDEF0123456789',
  num? size = 1024,
  num? status = 1,
  num? percentDone = 0.5,
}) => <String, dynamic>{
  if (name != null) 'name': name,
  if (hash != null) 'info_hash': hash,
  if (size != null) 'size': size,
  if (status != null) 'status': status,
  if (percentDone != null) 'percentDone': percentDone,
};

void main() {
  print('== 1. percentDone 标度自适应 ==');
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(percentDone: 0.5)],
    }).first.percent,
    50.0,
    '整包 ≤1 视为分数：0.5 → 50%',
  );
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(percentDone: 50)],
    }).first.percent,
    50.0,
    '整包 >1 视为百分数：50 → 50%',
  );
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(percentDone: 1.0), task(percentDone: 0.25)],
    }).first.percent,
    100.0,
    '分数标度下 1.0 → 100%（不得被误读为 1%）',
  );

  print('== 2. 状态码真值表 ==');
  checkEq(kPan115TaskStatus[0], '排队中', 'status=0 排队中');
  checkEq(kPan115TaskStatus[1], '下载中', 'status=1 下载中');
  checkEq(kPan115TaskStatus[2], '已完成', 'status=2 已完成');
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(status: 2, percentDone: 0.42)],
    }).first.percent,
    100.0,
    'status=2 即使进度不满也补齐 100%',
  );
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(status: 7)],
    }).first.statusLabel,
    '状态7',
    '未知状态码不猜测语义，原样透出',
  );

  print('== 3. finished / running 判定 ==');
  checkTrue(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(status: 2, percentDone: 1.0)],
    }).first.finished,
    'status=2 视为已完成',
  );
  checkTrue(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(status: 1, percentDone: 0.999)],
    }).first.finished,
    '进度 ≥99.5% 视为已完成（服务端偶发不置终态）',
  );
  checkTrue(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(status: 1, percentDone: 0.3)],
    }).first.running,
    'status=1 且进度 30% 视为进行中',
  );

  print('== 4. 字段容错 ==');
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(hash: 'AbC123')],
    }).first.infoHash,
    'abc123',
    'info_hash 统一小写',
  );
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(size: 2048)],
    }).first.sizeBytes,
    2048,
    'size 解析为 int',
  );
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(percentDone: 150)],
    }).first.percent,
    100.0,
    '越界进度钳制到 100',
  );
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[task(percentDone: 0.5), task(percentDone: 3.5)],
    }).first.percent,
    0.5,
    '整包含 >1 值 → 判定为百分数标度，0.5 即 0.5%',
  );
  checkEq(
    parsePan115Tasks(<String, dynamic>{
      'tasks': <dynamic>[
        <String, dynamic>{'name': '缺字段任务'},
      ],
    }).first.percent,
    0.0,
    '缺 percentDone 时回落 0（不伪造进度）',
  );
  checkEq(
    parsePan115Tasks(<String, dynamic>{'tasks': <dynamic>[]}).length,
    0,
    '空任务列表 → 空结果',
  );
  checkEq(parsePan115Tasks(null).length, 0, 'null 响应 → 空结果（不抛异常）');
  checkEq(parsePan115Tasks(<dynamic>[]).length, 0, '非 Map 响应 → 空结果');

  print('== 5. 整页解析：区分「掉线」与「没有任务」 ==');
  final pageFail = parsePan115TaskPage(<String, dynamic>{
    'state': false,
    'error': '登录超时，请重新登录。',
    'tasks': <dynamic>[],
  });
  checkTrue(!pageFail.ok, 'state=false → ok=false');
  checkEq(pageFail.message, '登录超时，请重新登录。', '透出服务端错误文案');
  final pageEmpty = parsePan115TaskPage(<String, dynamic>{
    'state': true,
    'tasks': <dynamic>[],
  });
  checkTrue(pageEmpty.ok, 'state=true 且无任务 → ok=true（不是错误）');
  final pageBad = parsePan115TaskPage('not json object');
  checkTrue(!pageBad.ok, '非对象响应 → ok=false');

  print('== 6. matchCloudTask 匹配优先级 ==');
  final pool = <Pan115CloudTask>[
    const Pan115CloudTask(
      name: 'The.Movie.2024.1080p',
      infoHash: 'hash1',
      sizeBytes: 0,
      percent: 10,
      statusCode: 1,
    ),
    const Pan115CloudTask(
      name: '中文资源名 4K',
      infoHash: 'hash2',
      sizeBytes: 0,
      percent: 20,
      statusCode: 1,
    ),
  ];
  checkEq(
    matchCloudTask(pool, remoteId: 'HASH1', target: '', title: '')?.infoHash,
    'hash1',
    'remote_id 精确命中（忽略大小写）',
  );
  checkEq(
    matchCloudTask(
      pool,
      remoteId: '',
      target: 'magnet:?xt=urn:btih:hash2&dn=x',
      title: '',
    )?.infoHash,
    'hash2',
    'magnet 链接内含 hash 命中',
  );
  checkEq(
    matchCloudTask(
      pool,
      remoteId: '',
      target: 'unknown',
      title: '中文资源名',
    )?.infoHash,
    'hash2',
    '标题互含兜底命中',
  );
  checkTrue(
    matchCloudTask(pool, remoteId: '', target: 'unknown', title: '毫不相关') ==
        null,
    '无匹配返回 null',
  );

  print('');
  print('通过 $_pass 条，失败 $_fail 条');
  if (_fail > 0) throw StateError('pan115_task_check 存在失败断言');
}
