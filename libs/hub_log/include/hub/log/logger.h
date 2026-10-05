// hub_log —— 独立日志模块（可从 baselib 单独剥离编译）
//
// 三条设计取向：
//   1. 简单实用：零第三方依赖，C++17，头文件即 API，流式写法 `HUB_LOG_INFO() << ...`
//   2. 可直接单测：行格式化是纯函数 `format_line()`，文件轮转可指向临时目录
//   3. 独立构建：`cmake -S . -B build` 即可单独编译并跑 ctest
//
// 用法：
//   hub::log::configure({.directory = "C:/path/.log", .min_level = Level::Debug});
//   HUB_LOG_INFO() << "115 login start";
#pragma once

#include <atomic>
#include <cstddef>
#include <memory>
#include <mutex>
#include <ostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace hub::log {

enum class Level : int { Debug = 0, Info = 1, Warn = 2, Error = 3 };

/// 级别标签（定宽 5 字符，便于对齐）
const char* level_tag(Level level);

/// 解析级别名（"debug"/"info"/"warn"/"error"，大小写不敏感）；非法值返回 Info
Level parse_level(const std::string& text);

struct Options {
  /// 日志文件目录；为空表示不落文件（只 stderr）
  std::string directory;
  /// 文件名前缀，最终为 <prefix>-<YYYYMMDD>.log
  std::string prefix = "hub";
  /// 单文件上限，超过即轮转
  std::size_t max_file_bytes = 2u * 1024 * 1024;
  /// 含当前文件在内保留的份数（>=1）
  int keep_files = 3;
  Level min_level = Level::Info;
  bool to_stderr = true;
  bool with_timestamp = true;
  bool with_thread = true;
};

/// 纯函数：组装一行日志文本。不触碰 IO，便于单测。
std::string format_line(Level level, const std::string& message,
                        bool with_timestamp, bool with_thread);

/// 输出目的地。默认实现为 stderr；文件则由 make_file_sink 提供。
class Sink {
 public:
  virtual ~Sink() = default;
  virtual void write(const std::string& line) = 0;
};

std::shared_ptr<Sink> make_stream_sink(std::ostream& stream);

/// 文件 sink：写 <directory>/<prefix>-<YYYYMMDD>.log，
/// 超过 max_file_bytes 轮转为 .1 / .2 …，超出 keep_files 的历史删除。
std::shared_ptr<Sink> make_file_sink(const std::string& directory,
                                     const std::string& prefix,
                                     std::size_t max_file_bytes, int keep_files);

class Logger {
 public:
  Logger();
  Logger(const Logger&) = delete;
  Logger& operator=(const Logger&) = delete;

  void configure(Options options);
  /// 回到初始态（仅 stderr），供单测复用进程
  void reset();

  void set_level(Level level);
  Level level() const;

  void add_sink(std::shared_ptr<Sink> sink);
  void write(Level level, const std::string& message);

  const Options& options() const;
  const std::vector<std::shared_ptr<Sink>>& sinks() const;
  /// 当前文件 sink 的绝对路径；未启用文件输出时为空
  std::string current_file() const;
  /// 因输出目的不可用而丢弃的行数
  std::size_t dropped() const;

 private:
  void ensure_default_sink();
  void install_file_sink(const Options& options);

  mutable std::mutex mu_;
  Options options_{};
  std::atomic<Level> level_{Level::Info};
  std::vector<std::shared_ptr<Sink>> sinks_;
  std::shared_ptr<Sink> file_sink_;
  std::string current_file_;
  std::atomic<std::size_t> dropped_{0};
};

/// 进程内共享实例
Logger& logger();

void configure(Options options);
void set_level(Level level);
Level level();
void write(Level level, const std::string& message);
std::string current_file();

/// 流式日志入口：析构时落盘。级别被过滤掉时不产生任何拼接开销。
class Entry {
 public:
  Entry(Level level, bool enabled) : level_(level), enabled_(enabled) {}
  ~Entry() {
    if (enabled_) write(level_, buf_.str());
  }

  Entry(const Entry&) = delete;
  Entry& operator=(const Entry&) = delete;

  template <typename T>
  Entry& operator<<(const T& value) {
    if (enabled_) buf_ << value;
    return *this;
  }

 private:
  Level level_;
  bool enabled_;
  std::ostringstream buf_;
};

}  // namespace hub::log

#define HUB_LOG_AT(level_expr)                                      \
  ::hub::log::Entry((level_expr),                                   \
                    static_cast<int>(level_expr) >=                 \
                        static_cast<int>(::hub::log::level()))

#define HUB_LOG_DEBUG() HUB_LOG_AT(::hub::log::Level::Debug)
#define HUB_LOG_INFO() HUB_LOG_AT(::hub::log::Level::Info)
#define HUB_LOG_WARN() HUB_LOG_AT(::hub::log::Level::Warn)
#define HUB_LOG_ERROR() HUB_LOG_AT(::hub::log::Level::Error)
