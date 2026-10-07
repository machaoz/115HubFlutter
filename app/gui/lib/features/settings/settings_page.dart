import 'package:flutter/material.dart';

import 'registry.dart';

/// 设置中心 —— **只做装配，不装任何业务**
///
/// 【重构前】本文件 1650 行，8 个设置域的 Card 类全部内联在这里，改一个域要在
/// 1650 行里来回翻，而且任何一处调整都会在本文件留下 diff。
///
/// 【重构后】每个设置域住在 `sections/*.dart`，由 `registry.dart` 的
/// `kSettingSections` 统一登记；布局由 `buildSettingsLayout` 按插槽拼。
/// 因此：**新增一个设置域 = 新建一个 section 文件 + 注册表追加一段常量**，
/// 本文件必须保持零改动。
///
/// 【为什么本页没有数据依赖】数据读取全部下沉到各自的 Section —— 它们自己是
/// Consumer*Widget，在内部 `ref.watch`。本页因此不再持有 TextEditingController，
/// 也不需要 dispose，可以直接写成 StatelessWidget。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 40),
      children: <Widget>[
        Text('设置中心', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 18),
        ...buildSettingsLayout(kSettingSections),
      ],
    );
  }
}
