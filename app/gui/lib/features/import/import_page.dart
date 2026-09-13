import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repos.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../core/util/image_loader.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// 导入后端抽象（PoC-2：WebView2 扫码取 Cookie 是最高风险项）
/// - RealBackend 依赖 desktop_webview_window 取 115 会话 Cookie，**待 PoC-2 验证**
/// - DemoBackend 保证离线回归可用（与 Electron 版「演示后端」口径一致）
abstract class ImportBackend {
  const ImportBackend();
  String get name;
  Future<TaskResult> submit(String kind, String target, {void Function(double)? onProgress});
}

class TaskResult {
  const TaskResult({required this.ok, this.remoteId = '', this.message = ''});
  final bool ok;
  final String remoteId;
  final String message;
}

/// 演示后端：确定性成功，用于打通「入队 → 执行 → 看板」全链路
class DemoBackend extends ImportBackend {
  const DemoBackend();

  @override
  String get name => '演示后端';

  @override
  Future<TaskResult> submit(String kind, String target,
      {void Function(double)? onProgress}) async {
    for (var i = 1; i <= 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 320));
      onProgress?.call(i / 5);
    }
    return const TaskResult(ok: true, remoteId: 'demo-id', message: '演示投递成功');
  }
}

/// 真后端占位：PoC-2（WebView2 扫码 + Cookie 仅内存持有）验证通过后启用。
/// 红线：凭证不落盘、不落库、不打印。
class RealBackend extends ImportBackend {
  const RealBackend();

  @override
  String get name => '115 真后端（待 PoC-2）';

  @override
  Future<TaskResult> submit(String kind, String target,
      {void Function(double)? onProgress}) async {
    throw StateError(
        'PoC-2（WebView2 内扫码取 Cookie）尚未通过验证，真后端暂未启用。'
        '可先在「设置 - 源适配器」开启演示源，或使用演示后端打通链路。');
  }
}

class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  ImportBackend _backend = const DemoBackend();

  Future<void> _runPending() async {
    final db = ref.read(appDatabaseProvider).maybeValue;
    if (db == null) return;
    final repo = ImportRepo(db);
    final rows = repo.list().where((r) => r['status'] == 'pending').toList();
    for (final r in rows) {
      final id = (r['id'] as num).round();
      repo.updateStatus(id, 'running', progress: 0);
      setState(() {});
      try {
        final res = await _backend.submit(
          r['kind'].toString(),
          r['target'].toString(),
          onProgress: (p) {
            repo.updateStatus(id, 'running', progress: (p * 100).round());
            if (mounted) setState(() {});
          },
        );
        repo.updateStatus(id, 'success', message: res.message, progress: 100);
      } catch (e) {
        repo.updateStatus(id, 'failed', message: '$e');
      }
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final db = ref.watch(appDatabaseProvider).maybeValue;
    final rows = db == null ? const <Map<String, Object?>>[] : ImportRepo(db).list();

    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        Text('115 导入', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('内嵌 WebView2 扫码登录 → 批量投递离线任务 → 任务看板（凭证不落盘）',
            style: TextStyle(color: t.textDim)),
        const SizedBox(height: 18),
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 860;
          const login = _LoginCard();
          final board = _TaskBoard(rows: rows);
          if (!wide) {
            return Column(children: <Widget>[login, const SizedBox(height: 16), board]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: 300, child: login),
              const SizedBox(width: 16),
              Expanded(child: board),
            ],
          );
        }),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          children: <Widget>[
            HubSegmented<ImportBackend>(
              label: '后端',
              items: const <(ImportBackend, String)>[
                (DemoBackend(), '演示后端'),
                (RealBackend(), '真后端'),
              ],
              value: _backend is DemoBackend ? const DemoBackend() : const RealBackend(),
              onChanged: (v) => setState(() => _backend = v),
            ),
            AccentButton(
                label: '执行待处理任务', icon: Icons.play_arrow, onPressed: _runPending),
            GhostButton(
              label: '清空已完成',
              icon: Icons.cleaning_services_outlined,
              onPressed: () {
                ImportRepo(ref.read(appDatabaseProvider).value!).clearFinished();
                setState(() {});
              },
            ),
          ],
        ),
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
    final proxy = ref.watch(appSettingsProvider).network.proxy;
    final busy = s.phase == SessionPhase.fetchingQr;
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
          Text('扫码登录',
              style:
                  TextStyle(color: t.textHi, fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 180,
              height: 180,
              child: s.qrUrl.isEmpty
                  ? Container(
                      decoration: BoxDecoration(
                        color: t.bg0,
                        border: Border.all(color: t.border),
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.qr_code_2, size: 54, color: t.textDim),
                    )
                  : RefererImage(
                      url: s.qrUrl,
                      referer: 'https://115.com/',
                      proxy: proxy,
                      placeholder: Container(
                        alignment: Alignment.center,
                        child: const SizedBox(
                            width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 14),
          HubChip(label: s.phase.label, selected: s.isLoggedIn, color: color),
          if (s.message.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(s.message,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.textDim, fontSize: 12.5)),
          ],
          if (s.phase == SessionPhase.waitingScan || s.phase == SessionPhase.scanned) ...<Widget>[
            const SizedBox(height: 6),
            Text('二维码 ${s.waitSeconds}s 后失效',
                style: TextStyle(color: t.textDim, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          Text('凭证仅内存持有，不落盘 / 不落库 / 不打印',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.textDim, fontSize: 12)),
          const SizedBox(height: 12),
          AccentButton(
            label: busy
                ? '获取中…'
                : (s.phase == SessionPhase.expired || s.phase == SessionPhase.failed
                    ? '重新获取二维码'
                    : (s.isLoggedIn ? '重新登录' : '发起扫码登录')),
            icon: Icons.qr_code_scanner,
            expand: true,
            onPressed: busy
                ? null
                : () {
                    ref.read(sessionProvider.notifier).configure(proxy: proxy);
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
  const _TaskBoard({required this.rows});
  final List<Map<String, Object?>> rows;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('投递队列看板',
              style: TextStyle(color: t.textHi, fontSize: 17, fontWeight: FontWeight.w700)),
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
                  style: TextStyle(color: t.textHi, fontWeight: FontWeight.w600),
                ),
              ),
              Text(status, style: TextStyle(color: color, fontSize: 12.5)),
            ],
          ),
          if (status == 'running') ...<Widget>[
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
          if (row['message'] != null && row['message'].toString().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(row['message'].toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.textDim, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }
}
