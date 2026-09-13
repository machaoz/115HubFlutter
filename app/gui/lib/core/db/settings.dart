import 'dart:convert';

import 'hub_database.dart';
import '../util/logger.dart';

typedef JsonMap = Map<String, dynamic>;

enum ThemeModePref { dark, light, system }

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
  }) =>
      NetworkSettings(
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
  }) =>
      RecommendSettings(
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
        refreshIntervalMinutes:
            clampInt(j?['refreshIntervalMinutes'], 360, 30, 10080),
        maxItemsPerBoard: clampInt(j?['maxItemsPerBoard'], 20, 5, 100),
        visibleBoards: ((j?['visibleBoards'] as List?) ??
                const <dynamic>['hot', 'latest', 'top-rated'])
            .map((e) => e.toString())
            .toList(),
        sourceId: (j?['sourceId'] as String?) ?? 'douban',
      );
}

/// 应用设置整包（对应 Electron 版 app_settings.settings_json）
class AppSettings {
  const AppSettings({
    this.theme = ThemeModePref.system,
    this.launchAtLogin = false,
    this.minimizeToTray = true,
    this.search = const SearchSettings(),
    this.recommend = const RecommendSettings(),
    this.network = const NetworkSettings(),
    this.autoBackup = true,
    this.retentionDays = 30,
  });

  final ThemeModePref theme;
  final bool launchAtLogin;
  final bool minimizeToTray;
  final SearchSettings search;
  final RecommendSettings recommend;
  final NetworkSettings network;
  final bool autoBackup;
  final int retentionDays;

  AppSettings copyWith({
    ThemeModePref? theme,
    bool? launchAtLogin,
    bool? minimizeToTray,
    SearchSettings? search,
    RecommendSettings? recommend,
    NetworkSettings? network,
    bool? autoBackup,
    int? retentionDays,
  }) =>
      AppSettings(
        theme: theme ?? this.theme,
        launchAtLogin: launchAtLogin ?? this.launchAtLogin,
        minimizeToTray: minimizeToTray ?? this.minimizeToTray,
        search: search ?? this.search,
        recommend: recommend ?? this.recommend,
        network: network ?? this.network,
        autoBackup: autoBackup ?? this.autoBackup,
        retentionDays: retentionDays ?? this.retentionDays,
      );

  JsonMap toJson() => <String, dynamic>{
        'general': <String, dynamic>{
          'theme': theme.name,
          'launchAtLogin': launchAtLogin,
          'minimizeToTray': minimizeToTray,
        },
        'search': search.toJson(),
        'recommend': recommend.toJson(),
        'network': network.toJson(),
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
    return AppSettings(
      theme: ThemeModePref.values.firstWhere(
        (t) => t.name == g['theme'],
        orElse: () => ThemeModePref.system,
      ),
      launchAtLogin: g['launchAtLogin'] == true,
      minimizeToTray: g['minimizeToTray'] != false,
      search: SearchSettings.from(j['search'] as JsonMap?),
      recommend: RecommendSettings.from(j['recommend'] as JsonMap?),
      network: NetworkSettings.from(j['network'] as JsonMap?),
      autoBackup: d['autoBackup'] != false,
      retentionDays: clampInt(d['retentionDays'], 30, 1, 365),
    );
  }
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
          <Object?>[jsonEncode(s.toJson()), DateTime.now().millisecondsSinceEpoch],
        );
      }
      return s;
    }

    try {
      final rows = _db.handle.select(
          'SELECT settings_json FROM app_settings WHERE id=1 LIMIT 1');
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
