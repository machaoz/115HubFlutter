import 'package:flutter/material.dart';

import 'sections/about_section.dart';
import 'sections/data_section.dart';
import 'sections/font_section.dart';
import 'sections/network_section.dart';
import 'sections/pan115_section.dart';
import 'sections/recommend_section.dart';
import 'sections/shell_layout_section.dart';
import 'sections/sound_section.dart';
import 'sections/sources_section.dart';
import 'sections/theme_section.dart';

/// 设置页分区插槽（对应原 `settings_page.dart` 的三种布局位置）
enum SettingsZone {
  /// 页面顶部通栏：主题 / 界面布局（4.0 的字体 · 图标也将落在这里）
  header,

  /// 宽屏时与 secondary 双列中的左列：源适配器
  primary,

  /// 宽屏时右列：搜索与网络 / 115 / 推荐 / 数据（4.0 的提示音）
  secondary,

  /// 页面底部通栏：关于
  footer,
}

/// 分区构造器。
///
/// 刻意不带参数：Section 自身是 Consumer*Widget，数据在它内部 `ref.watch`，
/// 令牌用 `context.t` 取。注册表因此不需要知道任何数据依赖 —— 这是
/// 「新增一个设置域只改一处文件」能成立的关键。
typedef SettingsSectionBuilder = Widget Function();

@immutable
class SettingsSectionDescriptor {
  const SettingsSectionDescriptor({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
    this.subtitle = '',
    this.keywords = const <String>[],
    this.zone = SettingsZone.secondary,
    this.order = 100,
  });

  /// 稳定 id（埋点 / 将来折叠态持久化 / 深层链接用）。**一旦发布不得修改**
  final String id;

  /// 卡片标题；4.0 设置搜索时作为主显示名
  final String title;

  /// 搜索结果 / 将来的分区导航用的图标
  final IconData icon;

  /// 标题下的一句说明（可选，用于搜索结果副标题）
  final String subtitle;

  /// 搜索关键词：中文同义词 + 英文。title 本身自动参与匹配，不必重复
  final List<String> keywords;

  final SettingsSectionBuilder builder;

  /// 所属插槽；默认 secondary（新域不指定也安全）
  final SettingsZone zone;

  /// 同插槽内升序排列；**步长给 10**，方便将来插缝不必重排所有序号
  final int order;

  /// 4.0 设置搜索的匹配入口（title/subtitle/keywords 全部受理）
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return false;
    return title.toLowerCase().contains(q) ||
        subtitle.toLowerCase().contains(q) ||
        keywords.any((k) => k.toLowerCase().contains(q));
  }
}

/// 设置分区注册表。
///
/// 【施工须知】新增一个设置域 = 本列表追加一段常量 + 新建一个 section 文件，
/// `settings_page.dart`（装配主体）**必须保持零改动**。
const List<SettingsSectionDescriptor> kSettingSections =
    <SettingsSectionDescriptor>[
      SettingsSectionDescriptor(
        id: 'theme',
        title: '主题',
        icon: Icons.palette_outlined,
        builder: ThemeSection.new,
        zone: SettingsZone.header,
        order: 10,
        keywords: <String>['主题', '配色', '颜色', '深色', '浅色', '主色', 'theme'],
      ),
      SettingsSectionDescriptor(
        id: 'font',
        title: '字体',
        icon: Icons.font_download_outlined,
        builder: FontSection.new,
        zone: SettingsZone.header,
        order: 15, // 插在 theme(10) 与 shellLayout(20) 之间
        keywords: <String>['字体', '字型', '中文字体', 'font', 'harmonyos'],
      ),
      SettingsSectionDescriptor(
        id: 'shellLayout',
        title: '界面布局',
        icon: Icons.view_sidebar_outlined,
        builder: ShellLayoutSection.new,
        zone: SettingsZone.header,
        order: 20,
        keywords: <String>['布局', '导航', '状态栏', 'layout', 'nav'],
      ),
      SettingsSectionDescriptor(
        id: 'sources',
        title: '源适配器',
        icon: Icons.hub_outlined,
        builder: SourcesSection.new,
        zone: SettingsZone.primary,
        order: 10,
        keywords: <String>['源', '数据源', '磁力', '协议', 'source'],
      ),
      SettingsSectionDescriptor(
        id: 'network',
        title: '搜索与网络',
        icon: Icons.lan_outlined,
        builder: NetworkSection.new,
        order: 10,
        keywords: <String>['代理', 'proxy', '并发', '结果上限', 'network'],
      ),
      SettingsSectionDescriptor(
        id: 'pan115',
        title: '115 会话',
        icon: Icons.cloud_outlined,
        builder: Pan115Section.new,
        order: 20,
        keywords: <String>['115', '设备', '槽位', '轮询', 'pan115'],
      ),
      SettingsSectionDescriptor(
        id: 'recommend',
        title: '首页推荐',
        icon: Icons.auto_awesome_outlined,
        builder: RecommendSection.new,
        order: 30,
        keywords: <String>['推荐', '豆瓣', '首页', 'recommend'],
      ),
      SettingsSectionDescriptor(
        id: 'data',
        title: '数据与桌面',
        icon: Icons.storage_outlined,
        builder: DataSection.new,
        order: 40,
        keywords: <String>['备份', '托盘', '启动页', '日志', 'backup'],
      ),
      SettingsSectionDescriptor(
        id: 'sound',
        title: '提示音',
        icon: Icons.volume_up_outlined,
        builder: SoundSection.new,
        subtitle: '任务 / 导入完成等节点的短提示音开关与音量',
        order: 45, // 排在 data(40) 之后、about(footer) 之前
        keywords: <String>['提示音', '音效', '声音', '静音', '音量', 'sound', 'volume'],
      ),
      SettingsSectionDescriptor(
        id: 'about',
        title: '关于',
        icon: Icons.info_outline,
        builder: AboutSection.new,
        zone: SettingsZone.footer,
        order: 10,
        keywords: <String>['关于', '版本', '许可', 'about', 'license'],
      ),
    ];

/// 把可见分区按插槽拼成一列 children。
///
/// 宽窄分支与重构前一致（内容宽 > 900 走双列），
/// **primary 为空时自动退化为单列**，避免将来删掉某个分区后留下空半屏。
List<Widget> buildSettingsLayout(List<SettingsSectionDescriptor> sections) {
  List<SettingsSectionDescriptor> take(SettingsZone z) {
    final list = sections.where((s) => s.zone == z).toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  Widget stack(List<SettingsSectionDescriptor> ss) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (var i = 0; i < ss.length; i++) ...<Widget>[
        ss[i].builder(),
        if (i != ss.length - 1) const SizedBox(height: 16),
      ],
    ],
  );

  final header = take(SettingsZone.header);
  final footer = take(SettingsZone.footer);
  final primary = take(SettingsZone.primary);
  final secondary = take(SettingsZone.secondary);

  return <Widget>[
    if (header.isNotEmpty) ...<Widget>[
      stack(header),
      // 对齐 HEAD 版 `settings_page.dart:87`：header 末尾与下方双列之间原本隔 16px，
      // 漏掉这一格会让主题/字体/界面布局三张卡直接贴住双列。
      const SizedBox(height: 16),
    ],
    LayoutBuilder(
      builder: (context, c) {
        // 900 沿用重构前；将来应替换为 AppBreakpoints（UI 规范 §3.7，属 P0-3）
        if (c.maxWidth <= 900 || primary.isEmpty) {
          return stack(<SettingsSectionDescriptor>[...primary, ...secondary]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: stack(primary)),
            const SizedBox(width: 16),
            Expanded(child: stack(secondary)),
          ],
        );
      },
    ),
    if (footer.isNotEmpty) ...<Widget>[
      const SizedBox(height: 16),
      stack(footer),
    ],
  ];
}
