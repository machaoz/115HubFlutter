// hub/network/health_probe.h —— 源健康度探测（原生能力预留位，首版为确定性桩）
#pragma once

#include <cstdint>
#include <string>

namespace hub::network {

enum class ProbeStatus : int32_t { kOk = 0, kTimeout = 1, kUnreachable = 2, kBadResponse = 3 };

struct ProbeResult {
  ProbeStatus status;
  int32_t latency_ms;  // -1 表示未测量
};

// 确定性桩实现：不做真实网络 IO，按 timeout_ms 返回 kTimeout 模拟探测语义。
// 真实探测在 Dart 侧 dio 完成；本桩仅保证 FFI 导出面与签名稳定。
ProbeResult probe(const std::string& url, int timeout_ms);

}  // namespace hub::network
