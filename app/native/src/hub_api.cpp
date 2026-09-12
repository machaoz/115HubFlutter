#include "hub/hub_api.h"

#include <cstring>
#include <mutex>
#include <string>

#include "hub/baselib/magnet_util.h"
#include "hub/baselib/version.h"
#include "hub/network/rate_limiter.h"
#include "hub/system/paths.h"
#include "hub/system/single_instance.h"
#include "hub/system/sys_info.h"

namespace {

std::string& app_data_cache() {
  static std::string v = hub::system::app_data_dir();
  return v;
}

hub::network::HostRateLimiter& limiter() {
  static hub::network::HostRateLimiter inst(1000);
  return inst;
}

int32_t write_hex40(char* out_hex41, const std::string& hex) {
  if (out_hex41 == nullptr) return HUB_ERR_INVALID_ARG;
  if (hex.size() != 40) return HUB_ERR_INVALID_ARG;
  std::memcpy(out_hex41, hex.c_str(), 41);  // 含 NUL
  return 40;
}

}  // namespace

extern "C" {

const char* hub_version(void) {
  static std::string v = std::string("1.0.0+abi.1 / baselib ") + hub::baselib::version();
  return v.c_str();
}

int32_t hub_self_check(void) {
  int32_t bits = 0x01 | 0x02 | 0x04;  // baselib / network / system 编入即视为可用
  // bit3: FTS5 能力位由 Dart 侧 PoC-1 实测（sqlite3_flutter_libs），原生默认未知
  return bits;
}

int32_t hub_sys_os_version(char* buf, int32_t len) {
  if (buf == nullptr || len <= 0) return HUB_ERR_INVALID_ARG;
  std::string v = hub::system::os_info().version;
  if (static_cast<int32_t>(v.size()) + 1 > len) return HUB_ERR_BUFFER_TOO_SMALL;
  std::snprintf(buf, static_cast<size_t>(len), "%s", v.c_str());
  return static_cast<int32_t>(v.size()) + 1;
}

const char* hub_sys_app_data_dir(void) { return app_data_cache().c_str(); }

int32_t hub_sys_single_instance_busy(const char* mutex_name) {
  if (mutex_name == nullptr) return HUB_ERR_INVALID_ARG;
  hub::system::SingleInstance probe(mutex_name);
  // 探测语义：若拿不到锁说明已有进程持有 → 返回 1
  return probe.try_lock() ? 0 : 1;
}

int32_t hub_parse_magnet_infohash(const char* uri, char* out_hex41) {
  if (uri == nullptr || out_hex41 == nullptr) return HUB_ERR_INVALID_ARG;
  auto info = hub::baselib::parse_magnet(uri);
  if (!info.has_value()) return HUB_ERR_INVALID_ARG;
  return write_hex40(out_hex41, info->infohash);
}

int32_t hub_parse_pan115_sha1(const char* uri, char* out_hex41) {
  if (uri == nullptr || out_hex41 == nullptr) return HUB_ERR_INVALID_ARG;
  auto sha1 = hub::baselib::parse_pan115_sha1(uri);
  if (!sha1.has_value()) return HUB_ERR_INVALID_ARG;
  return write_hex40(out_hex41, *sha1);
}

int32_t hub_net_rate_acquire(const char* host, int32_t min_interval_ms) {
  if (host == nullptr) return HUB_ERR_INVALID_ARG;
  (void)min_interval_ms;  // 间隔在初始化时固定为 1s（1 req/s 起步），细化排期在 P1
  return limiter().acquire(host);
}

int32_t hub_sha1_file(const char* path, char* out_hex41, hub_progress_cb progress) {
  (void)path;
  (void)out_hex41;
  (void)progress;
  return HUB_ERR_NOT_IMPLEMENTED;  // vNext：秒传校验场景再实现
}

}  // extern "C"
