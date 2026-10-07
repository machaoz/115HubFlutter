import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/settings.dart';
import '../../../state/providers.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// 搜索与网络设置域
///
/// 【为什么自己持有 TextEditingController】
/// 这三个输入框原来是装配主体持有、并在它的 `_save()` 里统一落库。
/// 注册化后装配主体不再认识任何具体分区，因此 controller 归本分区自己
/// 持有并在 `dispose()` 里释放；装配主体因此不再需要知道「有几个输入框」。
///
/// 【历史包袱】
/// `SearchSettings.maxResults/concurrency` 语义上属于「搜索」而非「网络」，
/// 本次照原样一并保存，避免牵动 P0-2 之外的 diff。
class NetworkSection extends ConsumerStatefulWidget {
  const NetworkSection({super.key});

  @override
  ConsumerState<NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends ConsumerState<NetworkSection> {
  final TextEditingController _proxy = TextEditingController();
  final TextEditingController _maxResults = TextEditingController();
  final TextEditingController _concurrency = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = ref.read(appSettingsProvider);
      _proxy.text = s.network.proxy;
      _maxResults.text = '${s.search.maxResults}';
      _concurrency.text = '${s.search.concurrency}';
    });
  }

  @override
  void dispose() {
    _proxy.dispose();
    _maxResults.dispose();
    _concurrency.dispose();
    super.dispose();
  }

  void _save() {
    final s = ref.read(appSettingsProvider);
    ref
        .read(appSettingsProvider.notifier)
        .update(
          s.copyWith(
            network: s.network.copyWith(proxy: _proxy.text.trim()),
            search: SearchSettings(
              maxResults:
                  int.tryParse(_maxResults.text.trim()) ?? s.search.maxResults,
              concurrency:
                  int.tryParse(_concurrency.text.trim()) ??
                  s.search.concurrency,
              cacheTtlMinutes: s.search.cacheTtlMinutes,
              sinceDays: s.search.sinceDays,
              blacklist: s.search.blacklist,
            ),
          ),
        );
    showHubToast(context, '设置已保存');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return HubCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '搜索与网络',
            style: TextStyle(
              color: t.textHi,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            textField: true,
            label: '代理地址',
            child: TextField(
              controller: _proxy,
              decoration: const InputDecoration(
                hintText: '代理，如 127.0.0.1:7890（留空直连）',
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _maxResults,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: 'maxResults'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _concurrency,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: '并发数'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AccentButton(
            label: '保存',
            icon: Icons.save_outlined,
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
