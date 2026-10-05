// 原生冒烟：逐项调用 hub_api 导出面，全部通过返回 0
#include <cstdio>
#include <cstring>

#include "hub/hub_api.h"

#define CHECK(expr, msg)                                     \
  do {                                                      \
    if (!(expr)) {                                           \
      std::fprintf(stderr, "[SMOKE-FAIL] %s\n", msg);       \
      return 1;                                             \
    }                                                       \
  } while (0)

int main() {
  const char* ver = hub_version();
  CHECK(ver != nullptr && ver[0] != '\0', "hub_version");

  int32_t bits = hub_self_check();
  CHECK((bits & 0x01) != 0, "self_check baselib");
  CHECK((bits & 0x02) != 0, "self_check network");
  CHECK((bits & 0x04) != 0, "self_check system");

  char os[64] = {0};
  int32_t n = hub_sys_os_version(os, sizeof(os));
  CHECK(n > 0, "os_version");

  const char* data_dir = hub_sys_app_data_dir();
  CHECK(data_dir != nullptr && data_dir[0] != '\0', "app_data_dir");

  char hex[41] = {0};
  int32_t r = hub_parse_magnet_infohash(
      "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=test", hex);
  CHECK(r == 40 && std::strlen(hex) == 40, "parse_magnet");
  CHECK(std::strcmp(hex, "0123456789abcdef0123456789abcdef01234567") == 0, "magnet hash value");

  r = hub_parse_pan115_sha1(
      "115://fedcba9876543210fedcba9876543210fedcba98|12345|name.iso", hex);
  CHECK(r == 40, "parse_pan115");

  // 解析失败路径
  CHECK(hub_parse_magnet_infohash("not-a-magnet", hex) == HUB_ERR_INVALID_ARG, "magnet reject");

  // 限流器：第一次 0，第二次 > 0
  int32_t w1 = hub_net_rate_acquire("example.com", 1000);
  int32_t w2 = hub_net_rate_acquire("example.com", 1000);
  CHECK(w1 == 0 && w2 > 0, "rate limiter");

  // vNext 占位
  CHECK(hub_sha1_file(nullptr, nullptr, nullptr) == HUB_ERR_NOT_IMPLEMENTED, "sha1 placeholder");

  // ---- 系统级密钥保护（DPAPI）：加密 → 解密 往返 + 密文非明文 + 篡改必须失败 ----
  char backend[16] = {0};
  CHECK(hub_secret_backend(backend, sizeof(backend)) > 0, "secret_backend");
  CHECK(std::strcmp(backend, "dpapi") == 0, "secret_backend value");

  const char* plain = "UID=1_A1_2; CID=abcdef; SEID=zzzz";
  const int32_t plain_len = static_cast<int32_t>(std::strlen(plain));

  // 第一次调用只问容量（out=nullptr）
  int32_t cap = 0;
  CHECK(hub_secret_protect(reinterpret_cast<const uint8_t*>(plain), plain_len, nullptr, &cap) ==
            HUB_ERR_BUFFER_TOO_SMALL,
        "secret_protect size query");
  CHECK(cap > plain_len, "ciphertext longer than plaintext");

  uint8_t cipher[512] = {0};
  int32_t cipher_len = sizeof(cipher);
  CHECK(hub_secret_protect(reinterpret_cast<const uint8_t*>(plain), plain_len, cipher,
                           &cipher_len) == HUB_OK,
        "secret_protect");
  CHECK(cipher_len > plain_len, "secret_protect length");
  CHECK(std::memcmp(cipher, plain, static_cast<size_t>(plain_len)) != 0,
        "ciphertext must not equal plaintext");

  uint8_t back[512] = {0};
  int32_t back_len = sizeof(back);
  CHECK(hub_secret_unprotect(cipher, cipher_len, back, &back_len) == HUB_OK,
        "secret_unprotect");
  CHECK(back_len == plain_len, "secret_unprotect length");
  CHECK(std::memcmp(back, plain, static_cast<size_t>(plain_len)) == 0, "roundtrip value");

  // 篡改密文（翻转最后一字节）必须解密失败，绝不返回脏数据
  cipher[cipher_len - 1] ^= 0xFF;
  int32_t tampered_len = sizeof(back);
  CHECK(hub_secret_unprotect(cipher, cipher_len, back, &tampered_len) != HUB_OK,
        "tampered blob rejected");
  cipher[cipher_len - 1] ^= 0xFF;

  // 入参边界
  CHECK(hub_secret_unprotect(nullptr, 0, back, &tampered_len) == HUB_ERR_INVALID_ARG,
        "unprotect invalid arg");

  std::printf("[SMOKE-OK] version=%s os=%s appdata=%s secret=%s\n", ver, os, data_dir,
              backend);
  return 0;
}
