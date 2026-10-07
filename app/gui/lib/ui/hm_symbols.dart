// hm_symbols.dart —— HarmonyOS Symbol 图标（OpenHarmony global_system_resources）
//
// 【来源与许可】
// 字形取自 HMSymbolVF.ttf（OpenHarmony global_system_resources 仓库，
// Apache License 2.0）。本工程按需子集化出 6 个字形落盘为
// assets/fonts/hm_symbol.ttf（3.4KB），许可全文随包：
// assets/fonts/hm_symbol_LICENSE.txt。
// 码位与 sys.symbol 逻辑名的对应关系（source: systemres/base/element/symbol.json）：
//   swap               0xF02D1
//   plus               0xF0035
//   pause              0xF00B1
//   play               0xF0350
//   xmark              0xF0056
//   arrow_2_circlepath 0xF00DC
//
// 【与 HubIcons 的关系】
// HubIcons（Fluent，MIT，生成文件 hub_icons.dart）覆盖全局导航/设置图标；
// 本类只承载媒体库工具栏新增的会话控制图标 —— 用户指定从 HarmonyOS 图标库
// 取用以获得清晰的开源协议，不与生成文件的码位空间混淆，**勿在此手动加码位**。
import 'package:flutter/widgets.dart';

/// 图标字体 family 名（pubspec.yaml 中声明）
const String kHmSymbolFamily = 'HMSymbol';

/// HarmonyOS Symbol 码位常量
class HmSymbols {
  HmSymbols._();

  /// 切源/交换（sys.symbol.swap）—— 115 与本地切换
  static const IconData swap = IconData(0xF02D1, fontFamily: kHmSymbolFamily);

  /// 添加（sys.symbol.plus）—— 添加本地路径扫描
  static const IconData plus = IconData(0xF0035, fontFamily: kHmSymbolFamily);

  /// 暂停（sys.symbol.pause）
  static const IconData pause = IconData(0xF00B1, fontFamily: kHmSymbolFamily);

  /// 播放/继续（sys.symbol.play）
  static const IconData play = IconData(0xF0350, fontFamily: kHmSymbolFamily);

  /// 取消/关闭（sys.symbol.xmark）
  static const IconData xmark = IconData(0xF0056, fontFamily: kHmSymbolFamily);

  /// 重新扫描（sys.symbol.arrow_2_circlepath）
  static const IconData rescan = IconData(0xF00DC, fontFamily: kHmSymbolFamily);
}
