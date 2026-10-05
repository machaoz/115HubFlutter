#include "hub/system/secret.h"

#if defined(_WIN32)

#include <windows.h>

#include <wincrypt.h>

namespace hub::system {
namespace {

// 附加熵：把密文与该应用绑定（同一用户下其他程序即使拿到密文也无法解开）
constexpr char kEntropy[] = "Magnetic115Hub/pan115/v1";

DATA_BLOB entropy_blob() {
  DATA_BLOB e{};
  e.cbData = static_cast<DWORD>(sizeof(kEntropy) - 1);
  e.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(kEntropy));
  return e;
}

}  // namespace

bool secret_available() { return true; }

const char* secret_backend() { return "dpapi"; }

std::optional<std::vector<uint8_t>> secret_protect(const uint8_t* data, size_t len) {
  if (data == nullptr && len != 0) return std::nullopt;
  DATA_BLOB in{};
  in.cbData = static_cast<DWORD>(len);
  // CryptProtectData 只读入参，这里去掉 const 是 Win32 API 的历史签名
  in.pbData = reinterpret_cast<BYTE*>(const_cast<uint8_t*>(data));
  DATA_BLOB entropy = entropy_blob();
  DATA_BLOB out{};
  if (CryptProtectData(&in, L"Magnetic115Hub", &entropy, nullptr, nullptr,
                       CRYPTPROTECT_UI_FORBIDDEN, &out) == FALSE) {
    return std::nullopt;
  }
  std::vector<uint8_t> result(out.pbData, out.pbData + out.cbData);
  LocalFree(out.pbData);
  return result;
}

std::optional<std::vector<uint8_t>> secret_unprotect(const uint8_t* blob, size_t len) {
  if (blob == nullptr || len == 0) return std::nullopt;
  DATA_BLOB in{};
  in.cbData = static_cast<DWORD>(len);
  in.pbData = reinterpret_cast<BYTE*>(const_cast<uint8_t*>(blob));
  DATA_BLOB entropy = entropy_blob();
  DATA_BLOB out{};
  if (CryptUnprotectData(&in, nullptr, &entropy, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &out) == FALSE) {
    return std::nullopt;
  }
  std::vector<uint8_t> result(out.pbData, out.pbData + out.cbData);
  if (out.pbData != nullptr) {
    // 明文缓冲用 SecureZeroMemory 擦除后再释放，避免残留在堆上
    SecureZeroMemory(out.pbData, out.cbData);
  }
  LocalFree(out.pbData);
  return result;
}

}  // namespace hub::system

#else  // 非 Windows：能力不可用，调用方降级为不持久化

namespace hub::system {

bool secret_available() { return false; }

const char* secret_backend() { return "none"; }

std::optional<std::vector<uint8_t>> secret_protect(const uint8_t*, size_t) {
  return std::nullopt;
}

std::optional<std::vector<uint8_t>> secret_unprotect(const uint8_t*, size_t) {
  return std::nullopt;
}

}  // namespace hub::system

#endif
