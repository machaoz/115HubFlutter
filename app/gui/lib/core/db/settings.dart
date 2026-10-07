import 'dart:convert';

import 'hub_database.dart';
import 'shell_layout.dart';
import '../navigation/app_route.dart';
import '../util/logger.dart';

// 壳层布局类型放在零依赖的 shell_layout.dart（可用纯 Dart 脚本复跑断言），
// 这里 re-export 让既有 `import '../core/db/settings.dart'` 的调用点无需改动。
export 'shell_layout.dart';

typedef JsonMap = Map<String, dynamic>;

enum ThemeModePref { dark, light, system }

/// 主题预设 id（持久化于 settings.general.themePreset）
/// 放在 core 层，避免 core → ui 的反向依赖；UI 侧在 `ui/theme.dart` 映射为具体令牌。
enum ThemePresetId {
  system,
  graphite,
  midnight,
  forest,
  paper,
  dawn,
  ocean,
  custom,
}

extension ThemePresetIdX on ThemePresetId {
  String get id => name;

  static ThemePresetId parse(String? raw, ThemePresetId fallback) {
    for (final v in ThemePresetId.values) {
      if (v.name == raw) return v;
    }
    return fallback;
  }
}

/// 界面图标风格（4.0 High-2「图标配置」放开给用户的一档）
///
/// 只作用于**导航/工具栏这类有成对「描边 + 填充」图标的位置**：
/// `PageDescriptor` 本来就同时提供 `icon`（描边）与 `activeIcon`（填充），
/// 这里决定「是否跟随选中态切换」。
///
/// 放在 core 层（与 [ThemePresetId] 同理），避免 core → ui 的反向依赖。
enum AppIconStyle {
  /// 跟随选中态：未选中描边、选中填充（4.0 之前的既有行为，保持默认）
  auto,

  /// 恒定描边：选中与否都用描边图标（更安静，接近 macOS 侧栏观感）
  outline,

  /// 恒定填充：选中与否都用填充图标（Windows 11 任务栏式）
  filled;

  static AppIconStyle parse(String? raw) {
    for (final v in AppIconStyle.values) {
      if (v.name == raw) return v;
    }
    return AppIconStyle.auto;
  }
}

/// 115 登录「绑定设备」目录
///
/// 【为什么必须显式选设备】115 的登录会话按 **app/设备类型分槽位**：
/// `POST passportapi.115.com/app/1.0/{app}/1.0/login/qrcode` 的 `{app}` 段决定
/// 本次登录占用哪个槽位。占用 `web` 槽位就会把用户浏览器的网页端会话顶下线。
/// 改用小程序 / 电视端等「用户平时不占用的槽位」即可与网页端并存、互不干扰。
///
/// 取证（2026-09）：
/// - AList 115 驱动文档：设备可选 Web/android/ios/tv/alipaymini/wechatmini/qandroid，
///   **明确不推荐 Web 与 Android(iOS)**，理由是「自己常用的设备登录后会将原本登录的挤下线」。
/// - python-115 作者 gist：`python -m p115 qrcode <app>`，社区实测 `wechatmini`、`tv` 可在
///   不顶号的前提下长期使用；换成 `linux` 仍会顶号（不顶号的前提是**换设备类型**，不是换名字）。
typedef Pan115App = ({String id, String label, bool conflicts});

/// `conflicts = true` 表示该槽位与用户常用端冲突（会顶号），UI 需给出橙色警示。
const List<Pan115App> kPan115Apps = <Pan115App>[
  (id: 'wechatmini', label: '微信小程序（推荐 · 与网页/手机互不影响）', conflicts: false),
  (id: 'alipaymini', label: '支付宝小程序（推荐 · 互不影响）', conflicts: false),
  (id: 'qandroid', label: '115 管理 Android（互不影响）', conflicts: false),
  (id: 'tv', label: '电视端（互不影响）', conflicts: false),
  (id: 'android', label: 'Android（会挤掉手机 App 登录）', conflicts: true),
  (id: 'ios', label: 'iOS（会挤掉 iPhone App 登录）', conflicts: true),
  (id: 'web', label: '网页版（会挤掉浏览器登录，V1.x 默认，不推荐）', conflicts: true),
];

const String kPan115DefaultApp = 'wechatmini';

/// 归一化设备 id：未知值回落默认（避免脏设置把登录打到不存在的槽位）
String normalizePan115App(String? raw) {
  for (final a in kPan115Apps) {
    if (a.id == raw) return a.id;
  }
  return kPan115DefaultApp;
}

Pan115App pan115AppOf(String id) =>
    kPan115Apps.firstWhere((a) => a.id == normalizePan115App(id));

/// 115 会话设置
class Pan115Settings {
  const Pan115Settings({
    this.loginApp = kPan115DefaultApp,
    this.pollCloudProgress = true,
    this.pollIntervalSeconds = 5,
  });

  /// 绑定设备槽位（见 kPan115Apps）
  final String loginApp;

  /// 是否轮询 115 离线任务列表，把云端真实进度回填到本地任务看板
  final bool pollCloudProgress;

  /// 轮询间隔（秒）
  final int pollIntervalSeconds;

  Pan115Settings copyWith({
    String? loginApp,
    bool? pollCloudProgress,
    int? pollIntervalSeconds,
  }) => Pan115Settings(
    loginApp: normalizePan115App(loginApp ?? this.loginApp),
    pollCloudProgress: pollCloudProgress ?? this.pollCloudProgress,
    pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
  );

  JsonMap toJson() => <String, dynamic>{
    'loginApp': loginApp,
    'pollCloudProgress': pollCloudProgress,
    'pollIntervalSeconds': pollIntervalSeconds,
  };

  static Pan115Settings from(JsonMap? j) => Pan115Settings(
    loginApp: normalizePan115App(j?['loginApp']?.toString()),
    pollCloudProgress: (j?['pollCloudProgress'] as bool?) ?? true,
    pollIntervalSeconds: clampInt(j?['pollIntervalSeconds'], 5, 3, 120),
  );
}

enum UaStrategy { rotate, fixed }

/// 网络设置（PoC-3：代理 / 限流 / UA / 超时）
class NetworkSettings {
  const NetworkSettings({
    this.proxy = '',
    this.timeoutMs = 8000,
    this.uaStrategy = UaStrategy.rotate,
    this.rateLimitPerHost = 1,
    this.humanize = true,
  });

  final String proxy;
  final int timeoutMs;
  final UaStrategy uaStrategy;
  final double rateLimitPerHost;
  final bool humanize;

  NetworkSettings copyWith({
    String? proxy,
    int? timeoutMs,
    UaStrategy? uaStrategy,
    double? rateLimitPerHost,
    bool? humanize,
  }) => NetworkSettings(
    proxy: proxy ?? this.proxy,
    timeoutMs: timeoutMs ?? this.timeoutMs,
    uaStrategy: uaStrategy ?? this.uaStrategy,
    rateLimitPerHost: rateLimitPerHost ?? this.rateLimitPerHost,
    humanize: humanize ?? this.humanize,
  );

  JsonMap toJson() => <String, dynamic>{
    'proxy': proxy,
    'timeoutMs': timeoutMs,
    'uaStrategy': uaStrategy.name,
    'rateLimitPerHost': rateLimitPerHost,
    'humanize': humanize,
  };

  static NetworkSettings from(JsonMap? j) => NetworkSettings(
    proxy: (j?['proxy'] as String?) ?? '',
    timeoutMs: clampInt(j?['timeoutMs'], 8000, 1000, 120000),
    uaStrategy: (j?['uaStrategy']?.toString() == 'fixed')
        ? UaStrategy.fixed
        : UaStrategy.rotate,
    rateLimitPerHost: clampNum(j?['rateLimitPerHost'], 1, 0.1, 50),
    humanize: (j?['humanize'] as bool?) ?? true,
  );
}

/// 本地媒体库设置（4.0 B1-S1：本轮只做本地视频源）
///
/// 【为什么扫描目录要进设置而不是写死在页面里】
/// 写死 = 每个用户第一次进媒体页都被扫同一个（多半不存在的）路径，扫不到也说不清
/// 为什么。进设置后口径统一为：**页面从设置读，用户在媒体页里改完写回设置**，
/// 下次启动还在；取不到（空串）时页面必须给出「选择目录」入口，
/// 不得自作主张拿 USERPROFILE / 盘根目录去扫。
class MediaSettings {
  const MediaSettings({this.directory = ''});

  /// 本地视频目录。空串 = 尚未配置。
  final String directory;

  bool get hasDirectory => directory.isNotEmpty;

  MediaSettings copyWith({String? directory}) =>
      MediaSettings(directory: directory ?? this.directory);

  JsonMap toJson() => <String, dynamic>{'directory': directory};

  static MediaSettings from(JsonMap? j) =>
      MediaSettings(directory: (j?['directory'] as String?)?.trim() ?? '');
}

/// 搜索设置
class SearchSettings {
  const SearchSettings({
    this.maxResults = 300,
    this.concurrency = 3,
    this.cacheTtlMinutes = 360,
    this.sinceDays = 0,
    this.blacklist = const <String>[],
  });

  final int maxResults;
  final int concurrency;
  final int cacheTtlMinutes;
  final int sinceDays;
  final List<String> blacklist;

  JsonMap toJson() => <String, dynamic>{
    'maxResults': maxResults,
    'concurrency': concurrency,
    'cacheTtlMinutes': cacheTtlMinutes,
    'sinceDays': sinceDays,
    'blacklist': blacklist,
  };

  static SearchSettings from(JsonMap? j) => SearchSettings(
    maxResults: clampInt(j?['maxResults'], 300, 0, 50000),
    concurrency: clampInt(j?['concurrency'], 3, 1, 16),
    cacheTtlMinutes: clampInt(j?['cacheTtlMinutes'], 360, 0, 10080),
    sinceDays: clampInt(j?['sinceDays'], 0, 0, 3650),
    blacklist: ((j?['blacklist'] as List?) ?? const <dynamic>[])
        .map((e) => e.toString())
        .toList(),
  );
}

/// 首页推荐设置
/// 【V1.1.0 预留】sourceId：首页数据源可切换（douban / tmdb / 自定义）
class RecommendSettings {
  const RecommendSettings({
    this.enabled = true,
    this.refreshIntervalMinutes = 360,
    this.maxItemsPerBoard = 20,
    this.visibleBoards = const <String>['hot', 'latest', 'top-rated'],
    this.sourceId = 'douban',
  });

  final bool enabled;
  final int refreshIntervalMinutes;
  final int maxItemsPerBoard;
  final List<String> visibleBoards;

  /// V1.1.0：首页数据源 id（当前仅 douban 可用，预留给 TMDB / 自定义）
  final String sourceId;

  RecommendSettings copyWith({
    bool? enabled,
    int? refreshIntervalMinutes,
    int? maxItemsPerBoard,
    List<String>? visibleBoards,
    String? sourceId,
  }) => RecommendSettings(
    enabled: enabled ?? this.enabled,
    refreshIntervalMinutes:
        refreshIntervalMinutes ?? this.refreshIntervalMinutes,
    maxItemsPerBoard: maxItemsPerBoard ?? this.maxItemsPerBoard,
    visibleBoards: visibleBoards ?? this.visibleBoards,
    sourceId: sourceId ?? this.sourceId,
  );

  JsonMap toJson() => <String, dynamic>{
    'enabled': enabled,
    'refreshIntervalMinutes': refreshIntervalMinutes,
    'maxItemsPerBoard': maxItemsPerBoard,
    'visibleBoards': visibleBoards,
    'sourceId': sourceId,
  };

  static RecommendSettings from(JsonMap? j) => RecommendSettings(
    enabled: (j?['enabled'] as bool?) ?? true,
    refreshIntervalMinutes: clampInt(
      j?['refreshIntervalMinutes'],
      360,
      30,
      10080,
    ),
    maxItemsPerBoard: clampInt(j?['maxItemsPerBoard'], 20, 5, 100),
    visibleBoards:
        ((j?['visibleBoards'] as List?) ??
                const <dynamic>['hot', 'latest', 'top-rated'])
            .map((e) => e.toString())
            .toList(),
    sourceId: (j?['sourceId'] as String?) ?? 'douban',
  );
}

/// 启动页定义集中处 —— 存 **route id 字符串**（见 AppRoute），不再存下标
///
/// 【为什么不再存 int】int 是「页面顺序」的隐式契约：插入一个新页，老用户的
/// 启动页就整段错位。改存 id 后顺序怎么调都不受影响。
class StartPage {
  const StartPage._();

  /// 可选启动页路由 —— **只给可见路由**。
  ///
  /// 不可见的页不能当启动页：用户选中后下次启动会因该页不在导航里而落到别处，
  /// 是「设置显示 A、实际落到 B」的静默不一致。
  static List<AppRoute> get startPageRoutes => AppRouteX.visibleValues;

  /// 下拉/选择器直接吃的选项：`(id:, label:)` 命名 record。
  ///
  /// 【为什么要这层包装】调用点不用 import 任何路由文件就能拿到 id 与中文标签，
  /// 也就不会「搬代码忘带 import」（`AppRoute.id`／`label` 是扩展成员，漏 import
  /// 会报 undefined_getter —— 这个坑在切分设置页时已经踩过两次）。
  static List<({String id, String label})> get startPageOptions =>
      startPageRoutes
          .map((r) => (id: r.id, label: r.label))
          .toList(growable: false);

  /// 脏值 → 安全回落：**绝不抛异常**
  ///
  /// 历史数据兼容：早期版本把启动页写成 int 下标（0 概览 … 5 设置），
  /// 也可能写成数字字符串。AppRouteX.parse 会按下标还原；越界/未知一律回落默认。
  /// 这里若抛异常，会被 SettingsRepo.get() 的 catch 吞掉并**整包重置设置**
  /// （ShellLayoutSettings 曾踩过这个坑），因此必须静默回落。
  static AppRoute startPageRoute(Object? raw) {
    final r = AppRouteX.parse(raw, AppRouteX.defaultStart);
    // 未完工（不可见）的路由即便库里存着也不生效，落回默认页
    return r.visible ? r : AppRouteX.defaultStart;
  }

  /// 归一化成可持久化的 route id
  static String normalizeStartPage(Object? raw) => startPageRoute(raw).id;
}

/// 应用设置整包（对应 Electron 版 app_settings.settings_json）
class AppSettings {
  const AppSettings({
    this.theme = ThemeModePref.system,
    this.themePreset = 'graphite',
    this.customDark = true,
    this.customAccent = 0xFFFF7A2F,
    this.fontFamily = 'harmonyOS',
    // 存字符串（与 fontFamily / themePreset 同口径）：settings 层不依赖 UI，
    // 且 `.name` 是 extension getter，不能出现在 const 表达式里。
    this.iconStyle = 'auto',
    this.soundEnabled = true,
    this.soundVolume = 0.7,
    this.launchAtLogin = false,
    this.minimizeToTray = true,
    this.startPage = 'discover',
    this.search = const SearchSettings(),
    this.recommend = const RecommendSettings(),
    this.network = const NetworkSettings(),
    this.media = const MediaSettings(),
    this.pan115 = const Pan115Settings(),
    this.shellLayout = const ShellLayoutSettings(),
    this.autoBackup = true,
    this.retentionDays = 30,
  });

  /// 旧字段（Electron 版共用 JSON 口径，保留写入）
  final ThemeModePref theme;

  /// 主题预设 id：system / graphite / midnight / forest / paper / dawn / ocean / custom
  final String themePreset;

  /// 自定义主题：明暗与主色（ARGB）
  final bool customDark;
  final int customAccent;

  /// 正文字体族：`system` 跟随系统默认 / `harmonyOS` 用包内 HarmonyOS Sans SC。
  /// 取值见 lib/ui/theme.dart 的 AppFontFamily（此处只存字符串，settings 层不依赖 UI）。
  final String fontFamily;

  /// 界面图标风格：auto / outline / filled（见 [AppIconStyle]）
  final String iconStyle;

  /// 提示音开关与音量（复用 media_kit Player 播放 assets/sounds 下的短音频）
  final bool soundEnabled;
  final double soundVolume;

  final bool launchAtLogin;
  final bool minimizeToTray;

  /// 启动后默认落地页 id（见 StartPage.startPageRoutes），默认「发现」
  final String startPage;

  final SearchSettings search;
  final RecommendSettings recommend;
  final NetworkSettings network;

  /// 本地媒体库（扫描目录等）
  final MediaSettings media;

  /// 115 会话（绑定设备槽位 + 云端进度轮询）
  final Pan115Settings pan115;

  /// 壳层布局（导航位置/标签、状态栏位置与内容）
  final ShellLayoutSettings shellLayout;

  final bool autoBackup;
  final int retentionDays;

  ThemePresetId get presetId =>
      ThemePresetIdX.parse(themePreset, ThemePresetId.graphite);

  AppSettings copyWith({
    ThemeModePref? theme,
    String? themePreset,
    bool? customDark,
    int? customAccent,
    String? fontFamily,
    String? iconStyle,
    bool? soundEnabled,
    double? soundVolume,
    bool? launchAtLogin,
    bool? minimizeToTray,
    String? startPage,
    SearchSettings? search,
    RecommendSettings? recommend,
    NetworkSettings? network,
    MediaSettings? media,
    Pan115Settings? pan115,
    ShellLayoutSettings? shellLayout,
    bool? autoBackup,
    int? retentionDays,
  }) => AppSettings(
    theme: theme ?? this.theme,
    themePreset: themePreset ?? this.themePreset,
    customDark: customDark ?? this.customDark,
    customAccent: customAccent ?? this.customAccent,
    fontFamily: fontFamily ?? this.fontFamily,
    iconStyle: AppIconStyle.parse(iconStyle ?? this.iconStyle).name,
    soundEnabled: soundEnabled ?? this.soundEnabled,
    soundVolume: soundVolume ?? this.soundVolume,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    minimizeToTray: minimizeToTray ?? this.minimizeToTray,
    startPage: StartPage.normalizeStartPage(startPage ?? this.startPage),
    search: search ?? this.search,
    recommend: recommend ?? this.recommend,
    network: network ?? this.network,
    media: media ?? this.media,
    pan115: pan115 ?? this.pan115,
    shellLayout: shellLayout ?? this.shellLayout,
    autoBackup: autoBackup ?? this.autoBackup,
    retentionDays: retentionDays ?? this.retentionDays,
  );

  JsonMap toJson() => <String, dynamic>{
    'general': <String, dynamic>{
      'theme': theme.name,
      'themePreset': themePreset,
      'customDark': customDark,
      'customAccent': customAccent,
      'fontFamily': fontFamily,
      'iconStyle': iconStyle,
      'soundEnabled': soundEnabled,
      'soundVolume': soundVolume,
      'launchAtLogin': launchAtLogin,
      'minimizeToTray': minimizeToTray,
      'startPage': startPage,
    },
    'search': search.toJson(),
    'recommend': recommend.toJson(),
    'network': network.toJson(),
    'media': media.toJson(),
    'pan115': pan115.toJson(),
    'shell': shellLayout.toJson(),
    'data': <String, dynamic>{
      'autoBackup': autoBackup,
      'retentionDays': retentionDays,
    },
  };

  /// 脏物料收敛到默认值 —— **设置损坏绝不崩溃**（《概要设计》§7）
  static AppSettings sanitize(JsonMap? raw) {
    final j = raw ?? const <String, dynamic>{};
    final g = (j['general'] as Map?) ?? const <String, dynamic>{};
    final d = (j['data'] as Map?) ?? const <String, dynamic>{};
    final legacyTheme = ThemeModePref.values.firstWhere(
      (t) => t.name == g['theme'],
      orElse: () => ThemeModePref.system,
    );
    // 旧库无 themePreset：由旧 theme 推导（dark→石墨极光 / light→冷调纸面 / system→跟随系统）
    final derived = switch (legacyTheme) {
      ThemeModePref.dark => 'graphite',
      ThemeModePref.light => 'paper',
      ThemeModePref.system => 'system',
    };
    final rawPreset = g['themePreset']?.toString();
    final preset = ThemePresetId.values.any((e) => e.name == rawPreset)
        ? rawPreset!
        : derived;
    return AppSettings(
      theme: legacyTheme,
      themePreset: preset,
      customDark: g['customDark'] != false,
      customAccent: clampInt(g['customAccent'], 0xFFFF7A2F, 0, 0xFFFFFFFF),
      // 旧库无 fontFamily：默认包内 HarmonyOS Sans（4.0 起随包内置）
      fontFamily: (g['fontFamily']?.toString() == 'system')
          ? 'system'
          : 'harmonyOS',
      // 旧库无 iconStyle → 保持既有观感（跟随选中态）
      iconStyle: AppIconStyle.parse(g['iconStyle']?.toString()).name,
      soundEnabled: g['soundEnabled'] != false,
      soundVolume: clampNum(g['soundVolume'], 0.7, 0, 1),
      launchAtLogin: g['launchAtLogin'] == true,
      minimizeToTray: g['minimizeToTray'] != false,
      startPage: StartPage.normalizeStartPage(g['startPage']?.toString()),
      search: SearchSettings.from(j['search'] as JsonMap?),
      recommend: RecommendSettings.from(j['recommend'] as JsonMap?),
      network: NetworkSettings.from(j['network'] as JsonMap?),
      // 旧库无 'media' → 空目录，页面据此弹「选择目录」入口
      media: MediaSettings.from(asMap(j['media'])),
      pan115: Pan115Settings.from(j['pan115'] as JsonMap?),
      // 旧库无 'shell'（也可能落在 general 下）→ 全取默认，且不因类型异常崩掉
      shellLayout: ShellLayoutSettings.from(
        asMap(j['shell']) ?? asMap(g['shell']),
      ),
      autoBackup: d['autoBackup'] != false,
      retentionDays: clampInt(d['retentionDays'], 30, 1, 365),
    );
  }
}

/// 宽松取 Map：非 Map 一律当缺失（设置 JSON 允许任何脏值，但不允许崩溃）
JsonMap? asMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) {
    final out = <String, dynamic>{};
    for (final entry in v.entries) {
      out[entry.key.toString()] = entry.value;
    }
    return out;
  }
  return null;
}

int clampInt(Object? v, int def, int min, int max) {
  final n = v is num ? v.round() : int.tryParse(v?.toString() ?? '');
  if (n == null) return def;
  return n < min ? min : (n > max ? max : n);
}

double clampNum(Object? v, double def, double min, double max) {
  final n = v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');
  if (n == null) return def;
  return n < min ? min : (n > max ? max : n);
}

/// 设置仓库：整包 JSON 单行存储 + 深合并更新
class SettingsRepo {
  SettingsRepo(this._db);
  final HubDatabase _db;

  AppSettings get() {
    AppSettings readDefault() {
      final s = AppSettings.sanitize(null);
      // 首次运行落默认值（只读模式下跳过）
      if (!_db.readOnly) {
        _db.handle.execute(
          'INSERT OR REPLACE INTO app_settings(id, settings_json, updated_at) VALUES(1,?,?)',
          <Object?>[
            jsonEncode(s.toJson()),
            DateTime.now().millisecondsSinceEpoch,
          ],
        );
      }
      return s;
    }

    try {
      final rows = _db.handle.select(
        'SELECT settings_json FROM app_settings WHERE id=1 LIMIT 1',
      );
      if (rows.isEmpty) return readDefault();
      final raw = rows.first['settings_json']?.toString();
      if (raw == null || raw.isEmpty) return readDefault();
      return AppSettings.sanitize(jsonDecode(raw) as JsonMap);
    } catch (e) {
      HubLogger.w('settings 解析损坏，回退默认值', e);
      return readDefault();
    }
  }

  AppSettings update(AppSettings next) {
    if (_db.readOnly) {
      HubLogger.w('只读模式下忽略设置写入');
      return next;
    }
    _db.handle.execute(
      'INSERT INTO app_settings(id, settings_json, updated_at) VALUES(1,?,?) '
      'ON CONFLICT(id) DO UPDATE SET settings_json=excluded.settings_json, '
      'updated_at=excluded.updated_at',
      <Object?>[
        jsonEncode(next.toJson()),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return next;
  }
}
