#include "hub/baselib/logger.h"

#include <atomic>
#include <cstdio>
#include <ctime>

namespace hub::baselib {

namespace {

std::atomic<LogLevel> g_level{LogLevel::kInfo};

const char* tag(LogLevel level) {
  switch (level) {
    case LogLevel::kDebug: return "DEBUG";
    case LogLevel::kInfo:  return "INFO ";
    case LogLevel::kWarn:  return "WARN ";
    case LogLevel::kError: return "ERROR";
  }
  return "?????";
}

}  // namespace

void set_log_level(LogLevel level) { g_level.store(level); }

void log(LogLevel level, const std::string& msg) {
  if (static_cast<int>(level) < static_cast<int>(g_level.load())) return;
  std::time_t now = std::time(nullptr);
  std::tm tmv{};
  localtime_s(&tmv, &now);
  std::fprintf(stderr, "[%04d-%02d-%02d %02d:%02d:%02d][hub][%s] %s\n",
               tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
               tmv.tm_hour, tmv.tm_min, tmv.tm_sec, tag(level), msg.c_str());
}

}  // namespace hub::baselib
