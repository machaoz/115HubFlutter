// hub_native_bindings.dart —— hub_native.dll 的 Dart FFI 绑定
// 由 app/native/include/hub/hub_api.h 对应手写（ffigen 自动生成排期在 P0 冻结后）
// 约定：字符串 UTF-8；返回 0 成功、负数为错误码（见 hub_api.h enum hub_errno）
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../util/app_paths.dart';

final class _HubError {
  const _HubError(this.code);
  final int code;
  @override
  String toString() => switch (code) {
    -1 => 'HUB_ERR_INVALID_ARG',
    -2 => 'HUB_ERR_NOT_IMPLEMENTED',
    -3 => 'HUB_ERR_IO',
    -4 => 'HUB_ERR_BUFFER_TOO_SMALL',
    _ => 'HUB_ERR_$code',
  };
}

/// hub_native.dll 唯一加载入口：优先 exe 同目录，再尝试当前工作目录与系统搜索路径。
DynamicLibrary _open() {
  const name = 'hub_native.dll';
  final candidates = <String>{
    p.join(HubPaths.installDir, name),
    p.join(Directory.current.path, name),
  };
  Object? lastError;
  for (final candidate in candidates) {
    if (!File(candidate).existsSync()) continue;
    try {
      return DynamicLibrary.open(candidate);
    } catch (e) {
      lastError = e;
    }
  }
  try {
    return DynamicLibrary.open(name);
  } catch (e) {
    throw ArgumentError.value(
      candidates.join(', '),
      'hubNativeSearchPaths',
      '无法加载 $name（最后错误：${lastError ?? e}）',
    );
  }
}

/// 惰性加载：DLL 缺失时仅原生能力降级，不在库导入阶段直接终止应用。
final DynamicLibrary _lib = _open();

bool get hubNativeAvailable {
  try {
    _lib;
    return true;
  } catch (_) {
    return false;
  }
}

typedef _VersionNative = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

/// 返回原生层版本串，例如 "1.0.0+abi.1 / baselib 1.0.0"
String hubVersion() {
  final f = _lib.lookupFunction<_VersionNative, _VersionDart>('hub_version');
  return f().toDartString();
}

typedef _SelfCheckNative = Int32 Function();
typedef _SelfCheckDart = int Function();

/// 原生能力位：bit0 baselib / bit1 network / bit2 system / bit3 sqlite-fts5
int hubSelfCheck() =>
    _lib.lookupFunction<_SelfCheckNative, _SelfCheckDart>('hub_self_check')();

typedef _OsVersionNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OsVersionDart = int Function(Pointer<Utf8>, int);

/// OS 版本（如 10.0.26200）；失败抛 [_HubError]
String hubOsVersion() {
  final f = _lib.lookupFunction<_OsVersionNative, _OsVersionDart>(
    'hub_sys_os_version',
  );
  final buf = malloc<Uint8>(64);
  try {
    final n = f(buf.cast(), 64);
    if (n <= 0) throw _HubError(n);
    return buf.cast<Utf8>().toDartString();
  } finally {
    malloc.free(buf);
  }
}

typedef _AppDataNative = Pointer<Utf8> Function();
typedef _AppDataDart = Pointer<Utf8> Function();

/// %APPDATA%\Magnetic115Hub（与 Electron 版 userData 口径一致）
String hubAppDataDir() {
  final f = _lib.lookupFunction<_AppDataNative, _AppDataDart>(
    'hub_sys_app_data_dir',
  );
  return f().toDartString();
}

typedef _ParseMagnetNative = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _ParseMagnetDart = int Function(Pointer<Utf8>, Pointer<Uint8>);

/// 解析 magnet 链接 → 40 位 infohash；失败抛 [_HubError]
String hubParseMagnetInfohash(String uri) {
  final f = _lib.lookupFunction<_ParseMagnetNative, _ParseMagnetDart>(
    'hub_parse_magnet_infohash',
  );
  final cUri = uri.toNativeUtf8();
  final out = malloc<Uint8>(41);
  try {
    final r = f(cUri, out);
    if (r != 40) throw _HubError(r);
    return out.cast<Utf8>().toDartString();
  } finally {
    malloc.free(cUri);
    malloc.free(out);
  }
}

typedef _RateNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _RateDart = int Function(Pointer<Utf8>, int);

/// host 级限流：返回需等待的毫秒数（0 = 立即可发）
int hubNetRateAcquire(String host) {
  final f = _lib.lookupFunction<_RateNative, _RateDart>('hub_net_rate_acquire');
  final c = host.toNativeUtf8();
  try {
    return f(c, 1000);
  } finally {
    malloc.free(c);
  }
}

// -------------------------------------------------------------- 系统级密钥保护
// Windows DPAPI：由操作系统按当前用户加密，本进程不生成也不保存密钥。
// 返回 null 表示「该平台无此能力」或「加解密失败」，调用方必须降级处理，
// 绝不把失败当成成功。

typedef _SecretProtectNative = Int32 Function(
  Pointer<Uint8>,
  Int32,
  Pointer<Uint8>,
  Pointer<Int32>,
);
typedef _SecretProtectDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  Pointer<Int32>,
);

const int _hubOk = 0;
const int _hubErrBufferTooSmall = -4;

/// 两段式调用（先问容量再取数据），避免任何长度猜测。
/// protect / unprotect 的 C 签名完全一致，共用同一组 typedef。
Uint8List? _secretCall(String symbol, Uint8List input) {
  final int Function(Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Int32>) fn;
  try {
    fn = _lib.lookupFunction<_SecretProtectNative, _SecretProtectDart>(symbol);
  } catch (_) {
    return null; // 旧版 dll 无该符号：视为不支持
  }
  if (input.isEmpty) return null;
  final inPtr = malloc<Uint8>(input.length);
  final outLenPtr = malloc<Int32>();
  try {
    inPtr.asTypedList(input.length).setAll(0, input);
    outLenPtr.value = 0;
    final probe = fn(inPtr, input.length, nullptr, outLenPtr);
    if (probe != _hubErrBufferTooSmall) return null;
    final need = outLenPtr.value;
    if (need <= 0) return null;

    final outPtr = malloc<Uint8>(need);
    try {
      final r = fn(inPtr, input.length, outPtr, outLenPtr);
      if (r != _hubOk) return null;
      final len = outLenPtr.value;
      if (len <= 0) return null;
      return Uint8List.fromList(outPtr.asTypedList(len));
    } finally {
      malloc.free(outPtr);
    }
  } catch (_) {
    return null;
  } finally {
    malloc.free(inPtr);
    malloc.free(outLenPtr);
  }
}

/// 用系统级密钥保护（Windows DPAPI）加密；不可用/失败返回 null
Uint8List? hubSecretProtect(Uint8List plain) =>
    _secretCall('hub_secret_protect', plain);

/// 解密 [hubSecretProtect] 产出的密文；密文被篡改或换了用户返回 null
Uint8List? hubSecretUnprotect(Uint8List blob) =>
    _secretCall('hub_secret_unprotect', blob);

/// 后端标识："dpapi" / "none" / 空串（dll 无该导出）
String hubSecretBackend() {
  try {
    final f = _lib.lookupFunction<_OsVersionNative, _OsVersionDart>(
      'hub_secret_backend',
    );
    final buf = malloc<Uint8>(16);
    try {
      final n = f(buf.cast(), 16);
      if (n <= 0) return '';
      return buf.cast<Utf8>().toDartString();
    } finally {
      malloc.free(buf);
    }
  } catch (_) {
    return '';
  }
}

// ------------------------------------------------------------------ 日志
// 原生侧日志由 libs/hub_log 提供（可单独编译、自带单元测试）。
// 应用启动后调用一次 hubLogInit，把原生日志目录指到「安装路径/.log」，
// 与 Dart 侧 hub.log 落同一处 —— 出问题时一个压缩包就能现场取证。

typedef _LogInitNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _LogInitDart = int Function(Pointer<Utf8>, int);

/// 初始化原生日志；[dir] 为空表示只输出 stderr。
/// 目录不可写时原生侧降级为 stderr，不抛错
void hubLogInit(String dir, {int minLevel = 0}) {
  try {
    final cDir = dir.toNativeUtf8();
    try {
      _lib.lookupFunction<_LogInitNative, _LogInitDart>('hub_log_init')(
        cDir,
        minLevel,
      );
    } finally {
      malloc.free(cDir);
    }
  } catch (_) {
    // 符号缺失（旧版 dll）：不影响启动，静默降级
  }
}

typedef _LogWriteNative = Int32 Function(Int32, Pointer<Utf8>);
typedef _LogWriteDart = int Function(int, Pointer<Utf8>);

/// 写一行原生日志（0=debug 1=info 2=warn 3=error）
void hubLogWrite(int level, String message) {
  try {
    final cMsg = message.toNativeUtf8();
    try {
      _lib.lookupFunction<_LogWriteNative, _LogWriteDart>('hub_log_write')(
        level,
        cMsg,
      );
    } finally {
      malloc.free(cMsg);
    }
  } catch (_) {
    // 同上
  }
}

typedef _LogFileNative = Pointer<Utf8> Function();
typedef _LogFileDart = Pointer<Utf8> Function();

/// 原生侧当前日志文件绝对路径；未启用文件输出返回空串
String hubLogCurrentFile() {
  try {
    return _lib
        .lookupFunction<_LogFileNative, _LogFileDart>('hub_log_current_file')()
        .toDartString();
  } catch (_) {
    return '';
  }
}
