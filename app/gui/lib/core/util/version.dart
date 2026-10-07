import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sq;

import '../native/hub_native_bindings.dart';

/// 版本信息单一来源（《概要设计》§版本口径）。
///
/// 构建期注入（见 `lunch` 的 `--dart-define`）：
///   HUB_APP_VERSION / HUB_FLUTTER_VERSION
/// 未注入时回落到代码内常量，保证 debug 直接 `flutter run` 也可用。
///
/// 注意：`FLUTTER_VERSION` 是 Flutter 框架保留的 dart-define 键，禁止占用，
/// 因此本项目统一使用 `HUB_` 前缀。
///
/// **禁止**在 UI 层硬编码版本号，一律读这里。
class BuildInfo {
  const BuildInfo._();

  /// 软件版本号（与 pubspec.yaml 的 version 保持同步）
  static const String appVersion = String.fromEnvironment(
    'HUB_APP_VERSION',
    defaultValue: '2.3.0',
  );

  /// Flutter 框架版本（构建期由 `flutter --version` 注入）
  static const String flutterVersion = String.fromEnvironment(
    'HUB_FLUTTER_VERSION',
    defaultValue: '3.47.3',
  );

  /// Dart / 引擎运行时版本（运行时读取，永远真实）
  static String get dartVersion {
    final v = Platform.version;
    final i = v.indexOf(' on ');
    return i > 0 ? v.substring(0, i) : v;
  }

  /// SQLite 库版本
  static String get sqliteVersion {
    try {
      return sq.sqlite3.version.libVersion;
    } catch (_) {
      return '不可用';
    }
  }

  /// 操作系统
  static String get osVersion {
    try {
      final v = hubOsVersion();
      return v.isEmpty ? Platform.operatingSystemVersion : 'Windows $v';
    } catch (_) {
      return Platform.operatingSystemVersion;
    }
  }

  /// 原生层（baselib / network / system）版本串；DLL 缺失时如实返回不可用
  static String get nativeVersion {
    try {
      return hubVersion();
    } catch (_) {
      return '不可用（hub_native.dll 未加载）';
    }
  }
}
