// 115HubFlutter · gui 骨架入口（P0 前占位）
//
// 当前形态：验证 Dart ↔ hub_native.dll FFI 链路的「原生自检页」。
// P0 开工后按《概要设计》§3.2 替换为 feature-first 六页结构：
//   features/{search,recommend,import,library,overview,settings}
import 'package:flutter/material.dart';

import 'core/native/hub_native_bindings.dart' as native;

void main() {
  runApp(const Magnetic115HubApp());
}

class Magnetic115HubApp extends StatelessWidget {
  const Magnetic115HubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Magnetic115Hub',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo, brightness: Brightness.dark)),
      themeMode: ThemeMode.system,
      home: const NativeSelfCheckPage(),
    );
  }
}

/// 原生层自检页：逐项展示 hub_native.dll 能力（FFI 端到端验证）
class NativeSelfCheckPage extends StatelessWidget {
  const NativeSelfCheckPage({super.key});

  List<(String, String, bool)> _probe() {
    final rows = <(String, String, bool)>[];
    String ver = '加载失败';
    try {
      ver = native.hubVersion();
      rows.add(('hub_version', ver, true));
    } catch (e) {
      rows.add(('hub_version', '$e', false));
      return rows;
    }
    final bits = native.hubSelfCheck();
    rows..add(('baselib', '版本/日志/magnet 解析', (bits & 0x01) != 0))
        ..add(('network', 'host 限流/探测桩', (bits & 0x02) != 0))
        ..add(('system', '单实例/OS 信息/路径', (bits & 0x04) != 0));
    rows.add(('FTS5 能力位', '由 Dart 侧 PoC-1 实测', (bits & 0x08) != 0));
    try {
      rows.add(('sys.os_version', native.hubOsVersion(), true));
      rows.add(('sys.app_data_dir', native.hubAppDataDir(), true));
      rows.add(('parse.magnet',
          native.hubParseMagnetInfohash(
              'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=probe'),
          true));
      rows.add(('net.rate_acquire(第1次)', '${native.hubNetRateAcquire('probe.local')} ms 等待', true));
      rows.add(('net.rate_acquire(第2次)', '${native.hubNetRateAcquire('probe.local')} ms 等待', true));
    } catch (e) {
      rows.add(('原生调用', '失败：$e', false));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _probe();
    return Scaffold(
      appBar: AppBar(title: const Text('115HubFlutter · 原生自检')),
      body: ListView.builder(
        itemCount: rows.length,
        itemBuilder: (context, i) {
          final (name, value, ok) = rows[i];
          return ListTile(
            leading: Icon(ok ? Icons.check_circle : Icons.cancel,
                color: ok ? Colors.green : Colors.red),
            title: Text(name),
            subtitle: Text(value, overflow: TextOverflow.ellipsis),
          );
        },
      ),
    );
  }
}
