#include "hub/network/rate_limiter.h"

namespace hub::network {

HostRateLimiter::HostRateLimiter(int min_interval_ms)
    : min_interval_ms_(min_interval_ms > 0 ? min_interval_ms : 1000) {}

int HostRateLimiter::acquire(const std::string& host) {
  std::lock_guard<std::mutex> lock(mu_);
  auto now = std::chrono::steady_clock::now();
  auto it = last_.find(host);
  if (it == last_.end() || now >= it->second) {
    last_[host] = now + std::chrono::milliseconds(min_interval_ms_);
    return 0;
  }
  auto wait_ms = static_cast<int>(
      std::chrono::duration_cast<std::chrono::milliseconds>(it->second - now).count());
  last_[host] = it->second + std::chrono::milliseconds(min_interval_ms_);
  return wait_ms < 0 ? 0 : wait_ms;
}

void HostRateLimiter::reset(const std::string& host) {
  std::lock_guard<std::mutex> lock(mu_);
  last_.erase(host);
}

void HostRateLimiter::reset_all() {
  std::lock_guard<std::mutex> lock(mu_);
  last_.clear();
}

}  // namespace hub::network
