import 'package:flutter_test/flutter_test.dart';
import 'package:magnetic115hub/core/network/pan115_tasks.dart';

/// W3 护栏：115 云端任务列表解析。
/// 若本机 flutter_tester 被拦，等价断言见 `.tools/pan115_task_check.dart`。
Map<String, dynamic> _task({
  String? name = '示例资源',
  String? hash = 'ABCDEF0123456789',
  num? size = 1024,
  num? status = 1,
  num? percentDone = 0.5,
}) => <String, dynamic>{
  'name': ?name,
  'info_hash': ?hash,
  'size': ?size,
  'status': ?status,
  'percentDone': ?percentDone,
};

List<Pan115CloudTask> _parse(List<Map<String, dynamic>> tasks) =>
    parsePan115Tasks(<String, dynamic>{'tasks': tasks});

void main() {
  group('percentDone 标度自适应', () {
    test('整包 ≤1 视为 0..1 分数', () {
      expect(
        _parse(<Map<String, dynamic>>[_task(percentDone: 0.5)]).first.percent,
        50.0,
      );
    });
    test('整包 >1 视为 0..100 百分数', () {
      expect(
        _parse(<Map<String, dynamic>>[_task(percentDone: 50)]).first.percent,
        50.0,
      );
    });
    test('分数标度下 1.0 → 100%，不得被误读为 1%', () {
      expect(
        _parse(<Map<String, dynamic>>[
          _task(percentDone: 1.0),
          _task(percentDone: 0.25),
        ]).first.percent,
        100.0,
      );
    });
    test('整包含 >1 值 → 判定为百分数标度', () {
      expect(
        _parse(<Map<String, dynamic>>[
          _task(percentDone: 0.5),
          _task(percentDone: 3.5),
        ]).first.percent,
        0.5,
      );
    });
    test('越界进度钳制到 100', () {
      expect(
        _parse(<Map<String, dynamic>>[_task(percentDone: 150)]).first.percent,
        100.0,
      );
    });
    test('缺 percentDone 时回落 0（不伪造进度）', () {
      expect(
        parsePan115Tasks(<String, dynamic>{
          'tasks': <dynamic>[
            <String, dynamic>{'name': '缺字段任务'},
          ],
        }).first.percent,
        0.0,
      );
    });
  });

  group('状态码真值表', () {
    test('0/1/2 的中文语义固定', () {
      expect(kPan115TaskStatus[0], '排队中');
      expect(kPan115TaskStatus[1], '下载中');
      expect(kPan115TaskStatus[2], '已完成');
    });
    test('status=2 即使进度不满也补齐 100%', () {
      expect(
        _parse(<Map<String, dynamic>>[_task(status: 2, percentDone: 0.42)])
            .first
            .percent,
        100.0,
      );
    });
    test('未知状态码不猜测语义', () {
      expect(
        _parse(<Map<String, dynamic>>[_task(status: 7)]).first.statusLabel,
        '状态7',
      );
    });
    test('finished / running 判定', () {
      expect(
        _parse(<Map<String, dynamic>>[_task(status: 2, percentDone: 1.0)])
            .first
            .finished,
        isTrue,
      );
      expect(
        _parse(<Map<String, dynamic>>[_task(status: 1, percentDone: 0.999)])
            .first
            .finished,
        isTrue,
        reason: '进度 ≥99.5% 视为已完成（服务端偶发不置终态）',
      );
      expect(
        _parse(<Map<String, dynamic>>[_task(status: 1, percentDone: 0.3)])
            .first
            .running,
        isTrue,
      );
    });
  });

  group('字段容错', () {
    test('info_hash 统一小写', () {
      expect(
        _parse(<Map<String, dynamic>>[_task(hash: 'AbC123')]).first.infoHash,
        'abc123',
      );
    });
    test('空列表 / null / 非 Map 一律空结果，不抛异常', () {
      expect(
        parsePan115Tasks(<String, dynamic>{'tasks': <dynamic>[]}),
        isEmpty,
      );
      expect(parsePan115Tasks(null), isEmpty);
      expect(parsePan115Tasks(<dynamic>[]), isEmpty);
    });
  });

  group('整页解析：区分掉线与没有任务', () {
    test('state=false → ok=false 并透出服务端文案', () {
      final p = parsePan115TaskPage(<String, dynamic>{
        'state': false,
        'error': '登录超时，请重新登录。',
        'tasks': <dynamic>[],
      });
      expect(p.ok, isFalse);
      expect(p.message, '登录超时，请重新登录。');
    });
    test('state=true 且无任务 → ok=true（不是错误）', () {
      final p = parsePan115TaskPage(<String, dynamic>{
        'state': true,
        'tasks': <dynamic>[],
      });
      expect(p.ok, isTrue);
      expect(p.tasks, isEmpty);
    });
    test('非对象响应 → ok=false', () {
      expect(parsePan115TaskPage('not a map').ok, isFalse);
    });
  });

  group('matchCloudTask 匹配优先级', () {
    const pool = <Pan115CloudTask>[
      Pan115CloudTask(
        name: 'The.Movie.2024.1080p',
        infoHash: 'hash1',
        sizeBytes: 0,
        percent: 10,
        statusCode: 1,
      ),
      Pan115CloudTask(
        name: '中文资源名 4K',
        infoHash: 'hash2',
        sizeBytes: 0,
        percent: 20,
        statusCode: 1,
      ),
    ];

    test('remote_id 精确命中（忽略大小写）', () {
      expect(
        matchCloudTask(
          pool,
          remoteId: 'HASH1',
          target: '',
          title: '',
        )?.infoHash,
        'hash1',
      );
    });
    test('magnet 链接内含 hash 命中', () {
      expect(
        matchCloudTask(
          pool,
          remoteId: '',
          target: 'magnet:?xt=urn:btih:hash2&dn=x',
          title: '',
        )?.infoHash,
        'hash2',
      );
    });
    test('标题互含兜底命中', () {
      expect(
        matchCloudTask(
          pool,
          remoteId: '',
          target: 'unknown',
          title: '中文资源名',
        )?.infoHash,
        'hash2',
      );
    });
    test('无匹配返回 null', () {
      expect(
        matchCloudTask(pool, remoteId: '', target: 'unknown', title: '毫不相关'),
        isNull,
      );
    });
  });
}
