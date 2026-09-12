// hub_native_bindings.dart —— hub_native.dll 的 Dart FFI 绑定
// 由 app/native/include/hub/hub_api.h 对应手写（ffigen 自动生成排期在 P0 冻结后）
// 约定：字符串 UTF-8；返回 0 成功、负数为错误码（见 hub_api.h enum hub_errno）
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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

/// hub_native.dll 唯一加载入口：先找 exe 同目录，再退回工作目录
DynamicLibrary _open() {
  const name = 'hub_native.dll';
  if (File(name).existsSync()) return DynamicLibrary.open(name);
  return DynamicLibrary.open(name);
}

final DynamicLibrary _lib = _open();

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
int hubSelfCheck() => _lib
    .lookupFunction<_SelfCheckNative, _SelfCheckDart>('hub_self_check')();

typedef _OsVersionNative = Int32 Function(Pointer<Utf8>, Int32);
typedef _OsVersionDart = int Function(Pointer<Utf8>, int);

/// OS 版本（如 10.0.26200）；失败抛 [_HubError]
String hubOsVersion() {
  final f = _lib.lookupFunction<_OsVersionNative, _OsVersionDart>('hub_sys_os_version');
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
  final f = _lib.lookupFunction<_AppDataNative, _AppDataDart>('hub_sys_app_data_dir');
  return f().toDartString();
}

typedef _ParseMagnetNative = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _ParseMagnetDart = int Function(Pointer<Utf8>, Pointer<Uint8>);

/// 解析 magnet 链接 → 40 位 infohash；失败抛 [_HubError]
String hubParseMagnetInfohash(String uri) {
  final f =
      _lib.lookupFunction<_ParseMagnetNative, _ParseMagnetDart>('hub_parse_magnet_infohash');
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
