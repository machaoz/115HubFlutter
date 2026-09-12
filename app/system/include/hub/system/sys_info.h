// hub/system/sys_info.h —— 系统信息（版本/架构），供诊断与日志上下文
#pragma once

#include <cstdint>
#include <string>

namespace hub::system {

struct OsInfo {
  std::string version;      // 如 "10.0.26200"
  uint32_t major = 0;
  uint32_t minor = 0;
  uint32_t build = 0;
  bool is_server = false;
};

OsInfo os_info();

// CPU 架构字符串："x64" / "arm64"
std::string cpu_arch();

}  // namespace hub::system
