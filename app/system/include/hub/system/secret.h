// hub/system/secret.h —— 系统级密钥保护（Windows DPAPI）
//
// 定位：把「必须落盘的敏感串」交给操作系统加密，应用自己**不实现也不持有密钥**。
// - Windows：CryptProtectData / CryptUnprotectData（用户态凭据，随当前用户账户加密）
// - 非 Windows：返回 nullopt（由调用方降级为「不持久化」）
//
// 【红线】本模块只做加解密，不碰文件 IO、不写日志、不打印内容。
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace hub::system {

// 该平台是否具备系统级密钥保护能力
bool secret_available();

// 后端标识："dpapi" / "none"
const char* secret_backend();

// 用当前用户凭据加密；失败返回 nullopt
std::optional<std::vector<uint8_t>> secret_protect(const uint8_t* data, size_t len);

// 解密由 secret_protect 产出的密文；失败（篡改/换用户/非本密文）返回 nullopt
std::optional<std::vector<uint8_t>> secret_unprotect(const uint8_t* blob, size_t len);

}  // namespace hub::system
