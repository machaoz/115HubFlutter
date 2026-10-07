import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repos.dart';
import '../../core/db/settings.dart';
import '../../state/cloud_sync_controller.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../core/util/image_loader.dart';
import '../../core/util/logger.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class TaskResult {
  const TaskResult({required this.ok, this.remoteId = '', this.message = ''});
  final bool ok;
  final String remoteId;
  final String message;
}

/// 115 离线投递真后端。
/// 【红线】凭证只从会话状态取用（内存 + 系统加密存储（DPAPI）），绝不落 SQLite / 落文件 / 打印。
/// 未登录 → 明确报错，**绝不伪造投递成功**。
class Pan115Backend {
  const Pan115Backend();

  String get name => '115 离线投递（需登录）';

  Future<TaskResult> submit(
    String kind,
    String target, {
    required String cookie,
    String proxy = '',
  }) async {
    if (cookie.isEmpty) {
      return const TaskResult(ok: false, message: '未登录 115：请先在左侧扫码登录');
    }
    if (kind == 'pan115' || target.startsWith('115://')) {
      return const TaskResult(
        ok: false,
        message: '115:// 秒传链接暂不支持离线投递（需网盘侧转存），请改用磁力/HTTP 链接',
      );
    }
    try {
      final d = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
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
      final res = await d.post<String>(
        'https://115.com/web/lixian/?ct=lixian&ac=add_task_url',
        data: <String, String>{'url': target},
        options: Options(
          headers: <String, String>{
            'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
            'referer': 'https://115.com/',
            'cookie': cookie,
            'content-type': 'application/x-www-form-urlencoded',
          },
        ),
      );
      final body = (res.data ?? '').trim();
      if (body.isEmpty) {
        return const TaskResult(ok: false, message: '115 返回空响应（可能已掉线，请重新登录）');
      }
      final Map<String, dynamic> json =
          jsonDecode(body) as Map<String, dynamic>;
      final ok = json['state'] == true || json['state'] == 1;
      final errno = json['errno']?.toString() ?? '';
      final msg = (json['error'] ?? json['message'] ?? '').toString();
      if (!ok) {
        return TaskResult(
          ok: false,
          message: msg.isNotEmpty ? msg : '115 拒绝该任务（errno=$errno）',
        );
      }
      final infoHash = (json['info_hash'] ?? json['infoHash'] ?? '').toString();
      return TaskResult(
        ok: true,
        remoteId: infoHash,
        message: infoHash.isEmpty ? '已提交到 115 离线任务' : '已提交：$infoHash',
      );
    } catch (e) {
      HubLogger.w('115 离线投递失败', e);
      return TaskResult(ok: false, message: '投递失败：$e');
    }
  }
}

class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  static const Pan115Backend _backend = Pan115Backend();

  /// 云端进度轮询已收敛到 `CloudSyncController`：本页不再自持 Timer。
  /// 「设置开关 + 已登录才轮询」由 controller 统一判断，本页只消费它的状态。
  CloudSyncController get _sync =>
      ref.read(cloudSyncControllerProvider.notifier);

  /// 清空**全部**本地导入记录（含排队 / 进行中）
  ///
  /// 必须二次确认，且明确「只清本机记录，不动 115 云端任务」——
  /// 用户最容易误解的就是这一步会连云端一起删。
  Future<void> _clearAll() async {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return;
    if (db.readOnly) {
      showHubToast(context, '数据为只读模式，无法清空导入记录');
      return;
    }
    final repo = ImportRepo(db);
    final total = repo.count();
    if (total == 0) {
      showHubToast(context, '暂无导入记录可清空');
      return;
    }
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('清空导入记录？'),
            content: Text(
              '将删除本机全部 $total 条导入记录（含排队与进行中）。\n\n'
              '只清本地记录，不会删除 115 云端已创建的离线任务；'
              '云端任务仍在你的 115 网盘中继续下载。\n\n'
              '此操作不可撤销。',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('清空'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    final removed = repo.clearAll();
    showHubToast(context, '已清空 $removed 条本地导入记录（115 云端任务未受影响）');
    // 本地队列变了，刷一遍快照（不打扰 115 接口）
    _sync.refreshLocal();
  }

  Future<void> _runPending() async {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return;
    final session = ref.read(sessionProvider);
    if (!session.isLoggedIn) {
      showHubToast(context, '未登录 115，请先扫码登录后再执行');
      return;
    }
    final cookie = session.cookie;
    final proxy = ref.read(appSettingsProvider).network.proxy;
    final repo = ImportRepo(db);
    final rows = repo.list().where((r) => r['status'] == 'pending').toList();
    if (rows.isEmpty) {
      showHubToast(context, '没有待处理任务');
      return;
    }
    for (final r in rows) {
      final id = (r['id'] as num).round();
      repo.updateStatus(id, 'running', progress: 0, message: '正在投递到 115…');

      final res = await _backend.submit(
        r['kind'].toString(),
        r['target'].toString(),
        cookie: cookie,
        proxy: proxy,
      );
      if (res.ok) {
        // 投递成功 ≠ 下载完成：进度交给云端列表回填，不再写死 100%
        repo.markSubmitted(id, remoteId: res.remoteId, message: res.message);
      } else {
        repo.updateStatus(id, 'failed', message: res.message);
      }
    }
    // 队列 row 现由 controller 统一出具：这儿一次性同步 + 刷新快照即可
    await _sync.syncNow();
    if (mounted) showHubToast(context, '投递完成，云端进度已同步');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // 与概览页共用同一份云端同步状态，两边看到的永远是同一批数据
    final cloud = ref.watch(cloudSyncControllerProvider);
    final loggedIn = ref.watch(sessionProvider).isLoggedIn;

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        Text('115 导入', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '官方二维码扫码登录 → 磁力链接离线投递 115 → 任务看板（进度取自 115 云端任务列表）',
          style: TextStyle(color: t.textDim),
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 860;
            const login = _LoginCard();
            final board = _TaskBoard(
              rows: cloud.rows,
              cloudNote: cloud.error ?? cloud.note,
              loggedIn: loggedIn,
              busy: cloud.syncing,
              onRefresh: _sync.syncNow,
            );
            if (!wide) {
              return Column(
                children: <Widget>[login, const SizedBox(height: 16), board],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(width: 300, child: login),
                const SizedBox(width: 16),
                Expanded(child: board),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            HubChip(
              label: _backend.name,
              selected: true,
              icon: loggedIn ? Icons.check_circle : Icons.lock_outline,
              color: loggedIn ? t.ok : t.warn,
            ),
            AccentButton(
              label: '执行待处理任务',
              icon: Icons.play_arrow,
              onPressed: loggedIn ? _runPending : null,
            ),
            GhostButton(
              label: '清空已完成',
              icon: Icons.cleaning_services_outlined,
              onPressed: () {
                // DB 仍在打开 / 打开失败时不做任何事，
                // 不能用 .value! 硬解包 —— 那样 loading/error 态会直接崩
                final db = ref.read(appDatabaseProvider).maybeValue;
                if (db == null) {
                  showHubToast(context, '数据库尚未就绪，请稍后再试');
                  return;
                }
                ImportRepo(db).clearFinished();
                _sync.refreshLocal();
              },
            ),
            GhostButton(
              label: '清空导入记录',
              icon: Icons.delete_sweep_outlined,
              onPressed: _clearAll,
            ),
          ],
        ),
        if (!loggedIn) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            '执行任务前需先完成 115 扫码登录（凭证存于系统加密存储（DPAPI），下次启动自动恢复）。',
            style: TextStyle(color: t.textDim, fontSize: 12.5),
          ),
        ],
      ],
    );
  }
}

/// 真实 115 扫码登录卡片：二维码来自官方接口，状态靠轮询，**绝不伪造成功**
class _LoginCard extends ConsumerWidget {
  const _LoginCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final s = ref.watch(sessionProvider);
    final settings = ref.watch(appSettingsProvider);
    final proxy = settings.network.proxy;
    final app = pan115AppOf(settings.pan115.loginApp);
    final showQr = s.qrUrl.isNotEmpty && !s.isLoggedIn;
    final color = switch (s.phase) {
      SessionPhase.loggedIn => t.ok,
      SessionPhase.failed || SessionPhase.expired => t.danger,
      SessionPhase.scanned => t.cyan,
      _ => t.textDim,
    };

    return HubCard(
      glow: true,
      child: Column(
        children: <Widget>[
          Text(
            '扫码登录',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 180,
              height: 180,
              child: !showQr
                  ? Container(
                      decoration: BoxDecoration(
                        color: t.bg0,
                        border: Border.all(color: t.border),
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.qr_code_2, size: 54, color: t.textDim),
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        RefererImage(
                          url: s.qrUrl,
                          referer: 'https://115.com/',
                          proxy: proxy,
                          placeholder: Container(
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                        if (s.phase == SessionPhase.expired ||
                            s.phase == SessionPhase.failed)
                          Container(
                            color: Colors.black.withValues(alpha: 0.6),
                            alignment: Alignment.center,
                            child: const Text(
                              '已失效\n请重新获取',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 14),
          HubChip(label: s.phase.label, selected: s.isLoggedIn, color: color),
          if (s.phase == SessionPhase.waitingScan ||
              s.phase == SessionPhase.scanned) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '二维码 ${s.waitSeconds}s 后失效',
              style: TextStyle(
                color: s.waitSeconds <= 20 ? t.danger : t.textDim,
                fontSize: 12,
              ),
            ),
          ],
          if (s.message.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              s.message,
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textDim, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 10),
          // 【W1】明确告知本次登录占用哪个设备槽位，让用户知道为什么不会顶掉网页端
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: <Widget>[
              HubChip(
                label: '绑定设备：${app.label.split('（').first}',
                icon: Icons.devices_other,
                selected: true,
                color: app.conflicts ? t.warn : t.ok,
              ),
            ],
          ),
          if (app.conflicts) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '该设备槽位会挤掉你正在使用的那一端，建议在「设置 - 115 会话」改用小程序/电视端。',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.warn, fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          // 【凭证存储口径】必须如实：Windows 版凭证会落到系统加密存储
          // （DPAPI 密文，密钥由操作系统按当前用户托管），
          // 但绝不写 SQLite、明文文件或日志。旧文案「仅内存持有」已过时。
          Text(
            s.credentialRestored
                ? '凭证已从系统加密存储恢复（DPAPI），不写数据库 / 不写日志'
                : (s.credentialPersisted
                      ? '凭证已存入系统加密存储（DPAPI），不写数据库 / 不写日志'
                      : '凭证未持久化：本次登录有效，下次启动需重新扫码'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: s.credentialRestored ? t.ok : t.textDim,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          AccentButton(
            label: s.phase == SessionPhase.fetchingQr
                ? '获取中…'
                : (s.phase == SessionPhase.expired ||
                          s.phase == SessionPhase.failed
                      ? '重新获取二维码'
                      : (s.isLoggedIn ? '重新登录' : '发起扫码登录')),
            icon: Icons.qr_code_scanner,
            expand: true,
            onPressed: s.phase == SessionPhase.fetchingQr
                ? null
                : () {
                    ref
                        .read(sessionProvider.notifier)
                        .configure(
                          proxy: proxy,
                          loginApp: settings.pan115.loginApp,
                        );
                    ref.read(sessionProvider.notifier).start();
                  },
          ),
          if (s.isLoggedIn) ...<Widget>[
            const SizedBox(height: 8),
            GhostButton(
              label: '退出登录',
              icon: Icons.logout,
              onPressed: () => ref.read(sessionProvider.notifier).logout(),
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskBoard extends StatelessWidget {
  const _TaskBoard({
    required this.rows,
    required this.cloudNote,
    required this.loggedIn,
    required this.busy,
    required this.onRefresh,
  });
  final List<Map<String, Object?>> rows;
  final String cloudNote;
  final bool loggedIn;
  final bool busy;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '投递队列看板',
                  style: TextStyle(
                    color: t.textHi,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: t.accent,
                    ),
                  ),
                ),
              GhostButton(
                label: '同步云端进度',
                icon: Icons.sync,
                onPressed: busy ? null : () => onRefresh(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            cloudNote.isEmpty
                ? (loggedIn ? '正在读取 115 云端任务进度…' : '未登录 115：仅显示本地队列状态')
                : cloudNote,
            style: TextStyle(
              color: loggedIn ? t.textDim : t.warn,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 14),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '暂无任务。可在「搜索」页对结果点「导入」入队，再回来执行。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.textDim),
                ),
              ),
            )
          else
            for (final r in rows.take(12)) _TaskRow(row: r, t: t),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.row, required this.t});
  final Map<String, Object?> row;
  final AppTokens t;

  @override
  Widget build(BuildContext context) {
    final status = row['status']?.toString() ?? 'pending';
    final color = switch (status) {
      'success' => t.ok,
      'failed' => t.danger,
      'running' => t.cyan,
      _ => t.textDim,
    };
    final progress = (row['progress'] as num?)?.round() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.bg1,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusDot(color: color, size: 8),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  row['title']?.toString().isNotEmpty == true
                      ? row['title'].toString()
                      : row['target'].toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.textHi,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                status == 'running' ? '$progress%' : status,
                style: TextStyle(color: color, fontSize: 12.5),
              ),
            ],
          ),
          if (status == 'running' || progress > 0) ...<Widget>[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: (progress / 100).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: t.bg0,
                valueColor: AlwaysStoppedAnimation<Color>(t.accent),
              ),
            ),
          ],
          if (row['message'] != null &&
              row['message'].toString().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              row['message'].toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.textDim, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}
