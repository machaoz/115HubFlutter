// hub/baselib/logger.h —— 原生侧极简分级日志（业务日志在 Dart 侧，本库只服务原生模块自检）
#pragma once

#include <string>

namespace hub::baselib {

enum class LogLevel : int { kDebug = 0, kInfo = 1, kWarn = 2, kError = 3 };

// 设置最低输出级别（默认 kInfo）；线程安全
void set_log_level(LogLevel level);

// 写一行日志（自动附加级别标签与换行）
void log(LogLevel level, const std::string& msg);

inline void log_debug(const std::string& msg) { log(LogLevel::kDebug, msg); }
inline void log_info(const std::string& msg) { log(LogLevel::kInfo, msg); }
inline void log_warn(const std::string& msg) { log(LogLevel::kWarn, msg); }
inline void log_error(const std::string& msg) { log(LogLevel::kError, msg); }

}  // namespace hub::baselib
