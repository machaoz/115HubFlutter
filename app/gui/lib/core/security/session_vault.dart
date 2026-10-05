import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../native/hub_native_bindings.dart';
import '../util/app_paths.dart';
import '../util/logger.dart';
import 'pan115_cookie.dart';

// 凭证解析/校验的纯函数在零依赖文件里，便于 `.tools` 纯 Dart 脚本复跑断言。
export 'pan115_cookie.dart';

/// 115 会话凭证（cookie 串 `UID=..; CID=..; SEID=..`）
///
/// 【红线】只在「内存」与「系统加密存储」之间流转：
/// 绝不写 SQLite / 明文文件 / 日志，任何 toString / 日志都不得携带 cookie。
class SessionCredential {
  const SessionCredential({
    required this.cookie,
    this.uid = '',
    this.loginApp = '',
  });

  /// 完整凭证串（敏感，禁止打印）
  final String cookie;

  /// 115 侧账号标识（qrcode token 的 uid）
  final String uid;

  /// 登录时占用的设备槽位（`app/1.0/{app}/...`）
  final String loginApp;

  bool get isValid => isValidPan115Cookie(cookie);

  /// 供测试与日志使用的键值视图（**不含原文**）
  Map<String, String> toJson() => <String, String>{
    'cookie': cookie,
    'uid': uid,
    'loginApp': loginApp,
  };

  static SessionCredential? fromJson(Map<String, dynamic> j) {
    final cookie = j['cookie']?.toString() ?? '';
    if (cookie.isEmpty) return null;
    return SessionCredential(
      cookie: cookie,
      uid: j['uid']?.toString() ?? '',
      loginApp: j['loginApp']?.toString() ?? '',
    );
  }
}

/// 凭证后端抽象（便于单测注入，**也是唯一允许接触凭证的出口**）
abstract class CredentialStore {
  Future<void> write({required String key, required String value});
  Future<String?> read({required String key});
  Future<void> delete({required String key});
}

/// 系统级加密存储后端（Windows DPAPI）
///
/// 落地形态：把三项凭证序列化成 JSON → 经 `hub_native.dll` 的
/// `hub_secret_protect`（Windows `CryptProtectData`）加密 → 密文写入
/// `%APPDATA%\Magnetic115Hub\credentials\pan115.bin`。
///
/// - 密钥由操作系统按「当前用户」托管，应用不生成也不持有密钥；
/// - 换用户账户 / 换机器一律解不开（解密失败即视为无凭证，回退扫码）；
/// - 全程不落明文：SQLite、日志、临时文件都没有原文。
class DpapiCredentialStore implements CredentialStore {
  DpapiCredentialStore({String? filePath})
    : _file = File(filePath ?? HubPaths.secretFilePath);

  final File _file;

  /// 解密后的键值视图（懒加载；null = 尚未读取）
  Map<String, String>? _cache;

  /// 该平台是否具备系统级加密能力（Windows 才有）
  static bool get supported =>
      hubNativeAvailable && hubSecretBackend() == 'dpapi';

  Future<Map<String, String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    if (!_file.existsSync()) return _cache = <String, String>{};
    try {
      final blob = await _file.readAsBytes();
      final plain = hubSecretUnprotect(blob);
      if (plain == null) {
        // 换了用户 / 密文损坏：清掉，避免每次启动都白试一次
        HubLogger.w('凭证密文无法解开（可能换了系统用户），已丢弃');
        await _file.delete().catchError((_) => _file);
        return _cache = <String, String>{};
      }
      final text = utf8.decode(plain);
      final decoded = jsonDecode(text);
      if (decoded is! Map) return _cache = <String, String>{};
      return _cache = decoded.map(
        (k, v) => MapEntry<String, String>(k.toString(), v?.toString() ?? ''),
      );
    } catch (e) {
      HubLogger.w('读取系统加密存储失败：${e.runtimeType}');
      return _cache = <String, String>{};
    }
  }

  Future<void> _flush(Map<String, String> data) async {
    if (!supported) throw StateError('平台不支持系统级加密存储');
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(data)));
    final blob = hubSecretProtect(plain);
    if (blob == null) throw StateError('加密失败');
    await _file.parent.create(recursive: true);
    // 先写临时文件再改名，避免半截文件把上次的有效凭证覆盖掉
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsBytes(blob, flush: true);
    await tmp.rename(_file.path);
  }

  @override
  Future<void> write({required String key, required String value}) async {
    final data = Map<String, String>.from(await _load());
    data[key] = value;
    await _flush(data);
    _cache = data;
  }

  @override
  Future<String?> read({required String key}) async {
    return (await _load())[key];
  }

  @override
  Future<void> delete({required String key}) async {
    final data = Map<String, String>.from(await _load());
    if (data.remove(key) == null) return;
    if (data.isEmpty) {
      _cache = <String, String>{};
      try {
        if (_file.existsSync()) await _file.delete();
      } catch (_) {
        // 删不掉也不影响「已登出」的语义
      }
      return;
    }
    await _flush(data);
    _cache = data;
  }
}

/// 内存后端：**仅供单测注入**，生产路径永远走 [DpapiCredentialStore]。
@visibleForTesting
class MemoryCredentialStore implements CredentialStore {
  /// 可见的存储内容，供断言（测试里放的是假凭证）
  final Map<String, String> data = <String, String>{};

  /// 置为 true 后所有操作抛异常，用于验证「凭证库故障不拖垮应用」
  bool fail = false;

  void _guard() {
    if (fail) throw StateError('credential store unavailable');
  }

  @override
  Future<void> write({required String key, required String value}) async {
    _guard();
    data[key] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    _guard();
    return data[key];
  }

  @override
  Future<void> delete({required String key}) async {
    _guard();
    data.remove(key);
  }
}

/// 115 会话凭证库。
///
/// 对外只暴露 save / restore / clear 三个动作；key 固定常量，
/// 任何存储异常都被就地消化（返回失败/空），**绝不向上抛出、绝不阻塞启动**。
class SessionVault {
  SessionVault(this._store);

  final CredentialStore _store;

  /// 键名带包名前缀，避免与同机其他 115 工具撞键
  static const String cookieKey = 'magnetic115hub.pan115.cookie';
  static const String uidKey = 'magnetic115hub.pan115.uid';
  static const String loginAppKey = 'magnetic115hub.pan115.login_app';

  static const List<String> allKeys = <String>[cookieKey, uidKey, loginAppKey];

  /// 写入系统加密存储。返回是否真正落盘成功。
  ///
  /// 失败时**调用方仍可保持内存登录**，只是下次启动需要重新扫码。
  Future<bool> save(SessionCredential cred) async {
    if (!cred.isValid) return false;
    try {
      await _store.write(key: cookieKey, value: cred.cookie);
      await _store.write(key: uidKey, value: cred.uid);
      await _store.write(key: loginAppKey, value: cred.loginApp);
      HubLogger.i('115 凭证已写入系统加密存储（不写数据库 / 不写日志）');
      return true;
    } catch (e) {
      // 只记类型：异常对象理论上不该含凭证，但没必要赌
      HubLogger.w('115 凭证写入系统加密存储失败：${e.runtimeType}');
      return false;
    }
  }

  /// 尝试从系统加密存储恢复。无凭证 / 残缺 / 存储不可用都返回 null。
  ///
  /// 残缺凭证会被顺手清掉，避免每次启动都重复一次无意义的恢复尝试。
  Future<SessionCredential?> restore() async {
    try {
      final cookie = await _store.read(key: cookieKey) ?? '';
      if (cookie.isEmpty) return null;
      if (!isValidPan115Cookie(cookie)) {
        HubLogger.w('系统加密存储中的 115 凭证残缺（缺 UID/CID/SEID），已丢弃');
        await clear();
        return null;
      }
      final uid = await _store.read(key: uidKey) ?? '';
      final app = await _store.read(key: loginAppKey) ?? '';
      return SessionCredential(cookie: cookie, uid: uid, loginApp: app);
    } catch (e) {
      // 存储不可用（DPAPI 失败 / dll 缺失）时静默降级为未登录
      HubLogger.w('读取系统加密存储失败（不影响启动）：${e.runtimeType}');
      return null;
    }
  }

  /// 退出登录 / 凭证失效时清除，best-effort（部分键失败也尽量清剩下的）
  Future<void> clear() async {
    for (final key in allKeys) {
      try {
        await _store.delete(key: key);
      } catch (e) {
        HubLogger.w('清除系统加密存储条目失败（$key）：${e.runtimeType}');
      }
    }
    HubLogger.i('115 凭证已从系统加密存储清除');
  }
}

/// 默认凭证库：Windows DPAPI 加密文件。
///
/// 系统能力不可用（非 Windows / dll 缺失）时**不需要换实现** ——
/// [DpapiCredentialStore] 自身会读写失败，[SessionVault] 把失败收敛为
/// 「本次登录有效但不记忆」，UI 不会崩，也不会伪造登录成功。
/// 单测可用 `overrideWithValue` 换成 [MemoryCredentialStore]。
final sessionVaultProvider = Provider<SessionVault>(
  (ref) => SessionVault(DpapiCredentialStore()),
);
