#include "hub/network/health_probe.h"

#include "hub/log/logger.h"

namespace hub::network {

ProbeResult probe(const std::string& url, int timeout_ms) {
  HUB_LOG_DEBUG() << "health_probe stub: " << url;
  // 桩语义：仅当给出非法超时时返回 kUnreachable，其余模拟超时结果
  if (timeout_ms <= 0) return {ProbeStatus::kUnreachable, -1};
  return {ProbeStatus::kTimeout, timeout_ms};
}

}  // namespace hub::network
