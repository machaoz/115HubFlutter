// hub_log 实现：分级过滤 + 多 sink 分发 + 按大小轮转的文件输出
#include "hub/log/logger.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>

namespace hub::log {
namespace fs = std::filesystem;

namespace {

std::tm local_tm(std::time_t t) {
  std::tm out{};
#if defined(_WIN32)
  localtime_s(&out, &t);
#else
  localtime_r(&t, &out);
#endif
  return out;
}

std::string date_stamp(const std::tm& tmv) {
  std::ostringstream os;
  os << (tmv.tm_year + 1900) << std::setfill('0') << std::setw(2)
     << (tmv.tm_mon + 1) << std::setw(2) << tmv.tm_mday;
  return os.str();
}

std::string timestamp() {
  const auto now = std::chrono::system_clock::now();
  const auto t = std::chrono::system_clock::to_time_t(now);
  const auto tmv = local_tm(t);
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      now.time_since_epoch()) %
                  1000;
  std::ostringstream os;
  os << (tmv.tm_year + 1900) << '-' << std::setfill('0') << std::setw(2)
     << (tmv.tm_mon + 1) << '-' << std::setw(2) << tmv.tm_mday << ' '
     << std::setw(2) << tmv.tm_hour << ':' << std::setw(2) << tmv.tm_min << ':'
     << std::setw(2) << tmv.tm_sec << '.' << std::setw(3) << ms.count();
  return os.str();
}

std::string thread_label() {
  const auto id = std::this_thread::get_id();
  return std::to_string(std::hash<std::thread::id>{}(id) % 100000u);
}

std::string lower(std::string s) {
  std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return s;
}

/// stderr sink：eof/fail 时静默丢弃，绝不抛给调用方
class StreamSink final : public Sink {
 public:
  explicit StreamSink(std::ostream& stream) : stream_(stream) {}
  void write(const std::string& line) override {
    std::lock_guard<std::mutex> lk(mu_);
    try {
      stream_ << line << '\n';
    } catch (...) {
    }
  }

 private:
  std::ostream& stream_;
  std::mutex mu_;
};

class FileSink final : public Sink {
 public:
  FileSink(std::string path, std::size_t max_bytes, int keep_files)
      : base_(std::move(path)), max_bytes_(max_bytes), keep_files_(keep_files) {
    open_current();
  }

  void write(const std::string& line) override {
    std::lock_guard<std::mutex> lk(mu_);
    if (!out_.is_open()) return;
    try {
      out_ << line << '\n';
      out_.flush();
    } catch (...) {
      return;
    }
    written_ += line.size() + 1;
    if (written_ >= max_bytes_) rotate();
  }

  const std::string& path() const { return base_; }

 private:
  void open_current() {
    std::error_code ec;
    if (base_.empty()) return;
    fs::create_directories(fs::path(base_).parent_path(), ec);
    std::size_t existing = 0;
    if (fs::exists(base_, ec)) {
      existing = fs::file_size(base_, ec);
      if (ec) existing = 0;
    }
    written_ = existing;
    out_.open(base_, std::ios::app | std::ios::out);
    if (written_ >= max_bytes_) rotate();
  }

  /// hub.log → hub.log.1 → hub.log.2 …，超出 keep_files 的历史直接删除
  void rotate() {
    out_.close();
    std::error_code ec;
    for (int i = keep_files_ - 1; i >= 1; --i) {
      const auto src = fs::path(base_ + (i == 1 ? "" : "." + std::to_string(i - 1)));
      const auto dst = fs::path(base_ + "." + std::to_string(i));
      if (i == keep_files_ - 1) fs::remove(dst, ec);
      if (fs::exists(src, ec)) fs::rename(src, dst, ec);
    }
    written_ = 0;
    out_.open(base_, std::ios::out | std::ios::trunc);
  }

  std::string base_;
  std::size_t max_bytes_;
  int keep_files_;
  std::size_t written_ = 0;
  std::ofstream out_;
  std::mutex mu_;
};

}  // namespace

const char* level_tag(Level level) {
  switch (level) {
    case Level::Debug: return "DEBUG";
    case Level::Info:  return "INFO ";
    case Level::Warn:  return "WARN ";
    case Level::Error: return "ERROR";
  }
  return "?????";
}

Level parse_level(const std::string& text) {
  const auto v = lower(text);
  if (v == "debug") return Level::Debug;
  if (v == "warn" || v == "warning") return Level::Warn;
  if (v == "error") return Level::Error;
  return Level::Info;
}

std::string format_line(Level level, const std::string& message,
                        bool with_timestamp, bool with_thread) {
  std::ostringstream os;
  if (with_timestamp) os << '[' << timestamp() << ']';
  os << '[' << level_tag(level) << ']';
  if (with_thread) os << "[tid=" << thread_label() << ']';
  os << ' ' << message;
  return os.str();
}

std::shared_ptr<Sink> make_stream_sink(std::ostream& stream) {
  return std::make_shared<StreamSink>(stream);
}

std::shared_ptr<Sink> make_file_sink(const std::string& directory,
                                     const std::string& prefix,
                                     std::size_t max_file_bytes,
                                     int keep_files) {
  if (directory.empty()) return nullptr;
  const auto tmv = local_tm(std::time(nullptr));
  const fs::path path = fs::path(directory) / (prefix + "-" + date_stamp(tmv) + ".log");
  return std::make_shared<FileSink>(path.string(), max_file_bytes,
                                    keep_files < 1 ? 1 : keep_files);
}

Logger::Logger() { ensure_default_sink(); }

void Logger::ensure_default_sink() {
  if (sinks_.empty()) sinks_.push_back(make_stream_sink(std::cerr));
}

void Logger::configure(Options options) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    options_ = std::move(options);
    level_.store(options_.min_level);
    dropped_.store(0);  // 重新配置视为新的统计周期
    file_sink_.reset();
    sinks_.clear();
    current_file_.clear();
    if (options_.to_stderr) ensure_default_sink();
    install_file_sink(options_);
  }
}

void Logger::install_file_sink(const Options& options) {
  try {
    file_sink_ = make_file_sink(options.directory, options.prefix,
                                options.max_file_bytes, options.keep_files);
  } catch (...) {
    file_sink_ = nullptr;  // 目录不可写不应拖垮启动流程
  }
  if (file_sink_) {
    if (const auto* file = dynamic_cast<const FileSink*>(file_sink_.get())) {
      current_file_ = file->path();
    }
    sinks_.push_back(file_sink_);
  }
}

void Logger::reset() {
  std::lock_guard<std::mutex> lk(mu_);
  options_ = Options{};
  level_.store(Level::Info);
  file_sink_.reset();
  sinks_.clear();
  current_file_.clear();
  ensure_default_sink();
}

void Logger::set_level(Level level) {
  level_.store(level);
  std::lock_guard<std::mutex> lk(mu_);
  options_.min_level = level;
}

Level Logger::level() const { return level_.load(); }

void Logger::add_sink(std::shared_ptr<Sink> sink) {
  if (!sink) return;
  std::lock_guard<std::mutex> lk(mu_);
  sinks_.push_back(std::move(sink));
}

void Logger::write(Level level, const std::string& message) {
  if (static_cast<int>(level) < static_cast<int>(level_.load())) return;
  const auto line =
      format_line(level, message, options_.with_timestamp, options_.with_thread);
  std::lock_guard<std::mutex> lk(mu_);
  if (sinks_.empty()) {
    dropped_.fetch_add(1);
    return;
  }
  for (const auto& s : sinks_) {
    if (s) s->write(line);
  }
}

const Options& Logger::options() const { return options_; }
const std::vector<std::shared_ptr<Sink>>& Logger::sinks() const { return sinks_; }
std::string Logger::current_file() const {
  std::lock_guard<std::mutex> lk(mu_);
  return current_file_;
}
std::size_t Logger::dropped() const { return dropped_.load(); }

Logger& logger() {
  static Logger g_logger;
  return g_logger;
}

void configure(Options options) { logger().configure(std::move(options)); }
void set_level(Level level) { logger().set_level(level); }
Level level() { return logger().level(); }
void write(Level level, const std::string& message) {
  logger().write(level, message);
}
std::string current_file() { return logger().current_file(); }

}  // namespace hub::log
