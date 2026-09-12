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

  std::printf("[SMOKE-OK] version=%s os=%s appdata=%s\n", ver, os, data_dir);
  return 0;
}
