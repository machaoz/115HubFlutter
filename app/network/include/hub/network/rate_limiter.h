// hub/network/rate_limiter.h —— host 级限流器（原生能力预留位；Dart 侧 dio 另有业务级实现）
#pragma once

#include <chrono>
#include <mutex>
#include <string>
#include <unordered_map>

namespace hub::network {

// 每 host 令牌间隔限流：acquire() 返回需要等待的毫秒数（0 = 立即可发）
class HostRateLimiter {
 public:
  // min_interval_ms：同一 host 两次请求的最小间隔（默认 1000ms = 1 req/s 起步）
  explicit HostRateLimiter(int min_interval_ms = 1000);

  // 返回本次应等待的毫秒数；线程安全
  int acquire(const std::string& host);

  // 清空某 host / 全部状态
  void reset(const std::string& host);
  void reset_all();

 private:
  int min_interval_ms_;
  std::mutex mu_;
  std::unordered_map<std::string, std::chrono::steady_clock::time_point> last_;
};

}  // namespace hub::network
