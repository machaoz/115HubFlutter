#include "hub/hub_api.h"

#include <cstdio>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "hub/baselib/magnet_util.h"
#include "hub/baselib/version.h"
#include "hub/log/logger.h"
#include "hub/media_scan.h"
#include "hub/media_scan_session.h"
#include "hub/network/rate_limiter.h"
#include "hub/system/paths.h"
#include "hub/system/secret.h"
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

// ---- 系统级密钥保护（DPAPI）----
namespace {

/// 公共缓冲区语义：*out_len 入参为容量、出参为实际（或所需）长度
int32_t copy_secret_result(const std::optional<std::vector<uint8_t>>& data,
                           uint8_t* out, int32_t* out_len) {
  if (out_len == nullptr) return HUB_ERR_INVALID_ARG;
  if (!data.has_value()) return HUB_ERR_IO;
  const auto size = static_cast<int32_t>(data->size());
  if (out == nullptr || *out_len < size) {
    *out_len = size;  // 通知调用方所需容量
    return HUB_ERR_BUFFER_TOO_SMALL;
  }
  if (size > 0) std::memcpy(out, data->data(), static_cast<size_t>(size));
  *out_len = size;
  return HUB_OK;
}

}  // namespace

int32_t hub_secret_protect(const uint8_t* plain, int32_t plain_len, uint8_t* out,
                           int32_t* out_len) {
  if (plain_len < 0 || (plain == nullptr && plain_len != 0)) {
    return HUB_ERR_INVALID_ARG;
  }
  if (!hub::system::secret_available()) return HUB_ERR_NOT_IMPLEMENTED;
  return copy_secret_result(
      hub::system::secret_protect(plain, static_cast<size_t>(plain_len)), out,
      out_len);
}

int32_t hub_secret_unprotect(const uint8_t* blob, int32_t blob_len, uint8_t* out,
                             int32_t* out_len) {
  if (blob_len <= 0 || blob == nullptr) return HUB_ERR_INVALID_ARG;
  if (!hub::system::secret_available()) return HUB_ERR_NOT_IMPLEMENTED;
  return copy_secret_result(
      hub::system::secret_unprotect(blob, static_cast<size_t>(blob_len)), out,
      out_len);
}

int32_t hub_secret_backend(char* buf, int32_t len) {
  if (buf == nullptr || len <= 0) return HUB_ERR_INVALID_ARG;
  std::string v = hub::system::secret_backend();
  if (static_cast<int32_t>(v.size()) + 1 > len) return HUB_ERR_BUFFER_TOO_SMALL;
  std::snprintf(buf, static_cast<size_t>(len), "%s", v.c_str());
  return static_cast<int32_t>(v.size()) + 1;
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

// ------------------------------------------------------------------ 媒体扫描
int32_t hub_media_scan(const char* root_utf8, int32_t max_depth, int32_t max_files,
                       char* out, int32_t out_cap, int32_t* out_len) {
  if (root_utf8 == nullptr || out_len == nullptr) return HUB_ERR_INVALID_ARG;
  if (out != nullptr && out_cap < 0) return HUB_ERR_INVALID_ARG;

  hub::media::ScanOptions opt;
  opt.max_depth = max_depth;  // <=0 由 media 模块回落默认值
  opt.max_files = max_files;

  std::vector<hub::media::ScanEntry> entries;
  const hub::media::ScanStatus st =
      hub::media::scan_directory(std::string(root_utf8), opt, &entries);
  if (st == hub::media::ScanStatus::kInvalidArg) return HUB_ERR_INVALID_ARG;
  if (st == hub::media::ScanStatus::kIo) return HUB_ERR_IO;

  const std::string json = hub::media::to_json_array(entries);
  // +1 带上结尾 NUL：Dart 侧拿到缓冲区可直接按 C 字符串读，不必再自己补零
  const int32_t need = static_cast<int32_t>(json.size()) + 1;
  *out_len = need;
  if (out == nullptr || out_cap < need) return HUB_ERR_BUFFER_TOO_SMALL;
  std::memcpy(out, json.data(), static_cast<size_t>(need));
  return HUB_OK;
}

// ---- 会话式扫描：状态 → JSON（{"state":"...","files":N,"dir":"..."}）----
namespace {

/// 两段式写出的公共尾：把 json 拷进 out（+NUL）；容量不足报 BUFFER_TOO_SMALL
int32_t write_json_out(const std::string& json, char* out, int32_t out_cap,
                       int32_t* out_len) {
  if (out_len == nullptr) return HUB_ERR_INVALID_ARG;
  const int32_t need = static_cast<int32_t>(json.size()) + 1;
  *out_len = need;
  if (out == nullptr || out_cap < need) return HUB_ERR_BUFFER_TOO_SMALL;
  std::memcpy(out, json.data(), static_cast<size_t>(need));
  return HUB_OK;
}

const char* scan_state_name(hub::media::ScanSessionState s) {
  switch (s) {
    case hub::media::ScanSessionState::kRunning: return "running";
    case hub::media::ScanSessionState::kPaused: return "paused";
    case hub::media::ScanSessionState::kDone: return "done";
    case hub::media::ScanSessionState::kCancelled: return "cancelled";
    case hub::media::ScanSessionState::kError: return "error";
  }
  return "error";
}

}  // namespace

int32_t hub_scan_start(const char* root_utf8, int32_t max_depth, int32_t max_files) {
  if (root_utf8 == nullptr) return HUB_ERR_INVALID_ARG;
  hub::media::ScanOptions opt;
  opt.max_depth = max_depth;
  opt.max_files = max_files;
  const int32_t id = hub::media::session::start(std::string(root_utf8), opt);
  if (id <= 0) {
    // 同步可判定的失败：空 root 按参数错，目录不存在/不可读按 IO 报
    return root_utf8[0] == '\0' ? HUB_ERR_INVALID_ARG : HUB_ERR_IO;
  }
  return id;
}

int32_t hub_scan_poll(int32_t session, char* out, int32_t out_cap,
                      int32_t* out_len) {
  hub::media::ScanSessionProgress p;
  if (!hub::media::session::progress(session, &p)) return HUB_ERR_INVALID_ARG;
  std::string json = "{\"state\":\"";
  json += scan_state_name(p.state);
  json += "\",\"files\":";
  json += std::to_string(p.files);
  json += ",\"dir\":";
  // dir 原样 UTF-8 透传，走一次 JSON 字符串转义防路径里的引号/反斜杠
  json += '"';
  for (unsigned char c : p.current_dir) {
    switch (c) {
      case '"': json += "\\\""; break;
      case '\\': json += "\\\\"; break;
      default: json.push_back(static_cast<char>(c)); break;
    }
  }
  json += "\"}";
  return write_json_out(json, out, out_cap, out_len);
}

int32_t hub_scan_pause(int32_t session) {
  return hub::media::session::pause(session) ? HUB_OK : HUB_ERR_INVALID_ARG;
}

int32_t hub_scan_resume(int32_t session) {
  return hub::media::session::resume(session) ? HUB_OK : HUB_ERR_INVALID_ARG;
}

int32_t hub_scan_cancel(int32_t session) {
  return hub::media::session::cancel(session) ? HUB_OK : HUB_ERR_INVALID_ARG;
}

int32_t hub_scan_result(int32_t session, char* out, int32_t out_cap,
                        int32_t* out_len) {
  if (out_len == nullptr) return HUB_ERR_INVALID_ARG;
  hub::media::ScanStatus st = hub::media::kOk;
  if (!hub::media::session::finished(session, &st)) return HUB_ERR_INVALID_ARG;
  if (st != hub::media::kOk) return HUB_ERR_IO;
  const std::vector<hub::media::ScanEntry> entries =
      hub::media::session::take(session, &st);
  return write_json_out(hub::media::to_json_array(entries), out, out_cap, out_len);
}

int32_t hub_scan_close(int32_t session) {
  // 幂等：会话不存在也返回 OK（关闭语义就是「此后别再用这个 id」）
  hub::media::session::close(session);
  return HUB_OK;
}

// ------------------------------------------------------------------ 日志
int32_t hub_log_init(const char* dir, int32_t min_level) {
  hub::log::Options opt;
  opt.directory = (dir == nullptr) ? std::string() : std::string(dir);
  opt.min_level = static_cast<hub::log::Level>(
      (min_level < 0 || min_level > 3) ? 1 : min_level);
  // debug 构建默认降到 DEBUG 级，便于现场取证；release 默认 INFO
  hub::log::configure(opt);
  HUB_LOG_INFO() << "hub_log ready, dir='" << opt.directory << "'";
  return HUB_OK;
}

int32_t hub_log_write(int32_t level, const char* message) {
  if (message == nullptr) return HUB_ERR_INVALID_ARG;
  if (level < 0 || level > 3) return HUB_ERR_INVALID_ARG;
  hub::log::write(static_cast<hub::log::Level>(level), std::string(message));
  return HUB_OK;
}

const char* hub_log_current_file(void) {
  // 跨天后文件名会变（按日期切文件），故每次取最新值再返回静态缓冲
  static std::mutex mu;
  std::lock_guard<std::mutex> lk(mu);
  static std::string v;
  v = hub::log::current_file();
  return v.c_str();
}

int32_t hub_sha1_file(const char* path, char* out_hex41, hub_progress_cb progress) {
  (void)path;
  (void)out_hex41;
  (void)progress;
  return HUB_ERR_NOT_IMPLEMENTED;  // vNext：秒传校验场景再实现
}

}  // extern "C"
