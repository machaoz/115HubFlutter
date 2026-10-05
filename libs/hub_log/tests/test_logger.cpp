// hub_log 单元测试：零第三方断言，覆盖分级过滤 / 行格式 / 文件轮转 / 线程安全
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "hub/log/logger.h"

namespace fs = std::filesystem;
using hub::log::Level;

namespace {

int g_failed = 0;
int g_passed = 0;

void check(bool ok, const std::string& name, const std::string& detail = "") {
  if (ok) {
    ++g_passed;
    std::cout << "  [ok]   " << name << '\n';
  } else {
    ++g_failed;
    std::cout << "  [FAIL] " << name << (detail.empty() ? "" : "  -> " + detail)
              << '\n';
  }
}

struct ScopedDir {
  std::string path;
  explicit ScopedDir(std::string p) : path(std::move(p)) {
    std::error_code ec;
    // 先清上一轮残留：Windows 上「文件句柄未释放 → remove_all 失败」会留下垃圾，
    // 下一轮 open(append) 就会把旧行也算进来，行数凭空翻倍。
    fs::remove_all(path, ec);
    fs::create_directories(path, ec);
  }
  ~ScopedDir() {
    // 先让 Logger 释放 FileSink（关闭句柄），再删目录
    hub::log::configure(hub::log::Options{});
    std::error_code ec;
    fs::remove_all(path, ec);
  }
};

std::size_t count_lines(const std::string& file) {
  std::ifstream in(file);
  std::size_t n = 0;
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty()) ++n;
  }
  return n;
}

std::size_t file_size(const std::string& file) {
  std::error_code ec;
  return fs::exists(file, ec) ? static_cast<std::size_t>(fs::file_size(file, ec)) : 0u;
}

void test_level_tag_and_parse() {
  std::cout << "case: level tag / parse\n";
  check(std::string(hub::log::level_tag(Level::Debug)) == "DEBUG", "tag(debug)");
  check(std::string(hub::log::level_tag(Level::Error)) == "ERROR", "tag(error)");
  check(hub::log::parse_level("DEBUG") == Level::Debug, "parse upper");
  check(hub::log::parse_level("warning") == Level::Warn, "parse warn alias");
  check(hub::log::parse_level("???") == Level::Info, "parse fallback=info");
}

void test_format_line() {
  std::cout << "case: format_line\n";
  const auto line = hub::log::format_line(Level::Warn, "disk full", true, true);
  check(line.find("[WARN ]") != std::string::npos, "contains level tag", line);
  check(line.find("disk full") != std::string::npos, "contains message", line);
  check(line.find("tid=") != std::string::npos, "contains thread id", line);
  check(line.rfind(']') < line.find("disk full"), "message after tags", line);

  const auto bare = hub::log::format_line(Level::Info, "hi", false, false);
  check(bare == "[INFO ] hi", "no timestamp/thread", bare);
}

void test_level_filter() {
  std::cout << "case: level filter\n";
  ScopedDir dir((fs::temp_directory_path() / "hub_log_filter").string());
  hub::log::Options opt;
  opt.directory = dir.path;
  opt.min_level = Level::Warn;
  opt.to_stderr = false;
  hub::log::configure(opt);
  check(hub::log::level() == Level::Warn, "level applied");

  hub::log::write(Level::Debug, "should be dropped");
  hub::log::write(Level::Info, "should be dropped");
  hub::log::write(Level::Warn, "kept-warn");
  hub::log::write(Level::Error, "kept-error");

  const auto path = hub::log::current_file();
  check(!path.empty() && fs::exists(path), "file created", path);
  check(count_lines(path) == 2, "only warn+error written",
        std::to_string(count_lines(path)));

  hub::log::set_level(Level::Debug);
  check(hub::log::level() == Level::Debug, "set_level works");
  hub::log::write(Level::Debug, "now visible");
  check(count_lines(path) == 3, "debug visible after downgrade",
        std::to_string(count_lines(path)));
}

void test_file_rotation() {
  std::cout << "case: rotation & retention\n";
  ScopedDir dir((fs::temp_directory_path() / "hub_log_rotate").string());
  hub::log::Options opt;
  opt.directory = dir.path;
  opt.prefix = "rot";
  opt.min_level = Level::Debug;
  opt.max_file_bytes = 512;  // 每条约 70B，写 ~10 条必轮转
  opt.keep_files = 3;
  opt.to_stderr = false;
  hub::log::configure(opt);

  for (int i = 0; i < 40; ++i) {
    hub::log::write(Level::Info, "rotate probe line " + std::to_string(i));
  }

  const auto base = hub::log::current_file();
  check(!base.empty() && fs::exists(base), "current file exists", base);
  check(file_size(base) <= opt.max_file_bytes, "current size capped",
        std::to_string(file_size(base)));
  check(fs::exists(base + ".1"), "first history exists");
  check(fs::exists(base + ".2"), "second history exists");
  check(!fs::exists(base + ".3"), "beyond keep_files pruned");

  // 轮转语义 = 保留 max_file_bytes × keep_files 的窗口，更早的行必然被回收；
  // 这里只断言「窗口内的行没丢」+「最新内容落在当前文件」
  std::size_t total = count_lines(base);
  for (const char* suffix : {".1", ".2"}) {
    total += count_lines(base + suffix);
  }
  check(total >= 15, "history keeps recent window", std::to_string(total));

  // 最新一批内容必须还活着（轮转把旧窗口整体后移，最新行必在前两份之一）
  auto read_tail_line = [](const std::string& file) {
    std::ifstream in(file);
    std::string line;
    std::string last;
    while (std::getline(in, line)) {
      if (!line.empty()) last = line;
    }
    return last;
  };
  const auto newest = std::string("rotate probe line 39");
  bool found_newest = read_tail_line(base).find(newest) != std::string::npos ||
                      read_tail_line(base + ".1").find(newest) != std::string::npos;
  check(found_newest, "newest line survives rotation",
        read_tail_line(base) + " | " + read_tail_line(base + ".1"));
}

void test_directory_empty_disables_file() {
  std::cout << "case: empty directory -> no file\n";
  hub::log::Options opt;
  opt.directory.clear();
  opt.to_stderr = false;
  hub::log::configure(opt);
  check(hub::log::current_file().empty(), "no file sink");
  check(hub::log::logger().sinks().empty(), "no sink at all");
  hub::log::write(Level::Error, "nowhere to go");
  check(hub::log::logger().dropped() == 1, "dropped counter increments");
}

void test_concurrent_write() {
  std::cout << "case: concurrent write\n";
  ScopedDir dir((fs::temp_directory_path() / "hub_log_mt").string());
  hub::log::Options opt;
  opt.directory = dir.path;
  opt.min_level = Level::Debug;
  opt.to_stderr = false;
  hub::log::configure(opt);

  constexpr int kThreads = 8;
  constexpr int kLines = 200;
  std::vector<std::thread> pool;
  for (int t = 0; t < kThreads; ++t) {
    pool.emplace_back([t] {
      for (int i = 0; i < kLines; ++i) {
        HUB_LOG_INFO() << "thread=" << t << " i=" << i;
      }
    });
  }
  for (auto& th : pool) th.join();

  const auto path = hub::log::current_file();
  std::ifstream in(path);
  std::string line;
  std::size_t n = 0;
  std::atomic<bool> broken{false};
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    if (line.find("thread=") == std::string::npos) broken.store(true);
    ++n;
  }
  check(n == kThreads * kLines, "no lost line", std::to_string(n));
  check(!broken.load(), "no interleaved line");
  check(hub::log::logger().dropped() == 0, "nothing dropped");
}

void test_stream_macro() {
  std::cout << "case: stream macro\n";
  ScopedDir dir((fs::temp_directory_path() / "hub_log_macro").string());
  hub::log::Options opt;
  opt.directory = dir.path;
  opt.min_level = Level::Debug;
  opt.to_stderr = false;
  hub::log::configure(opt);
  HUB_LOG_DEBUG() << "answer=" << 42 << " pi=" << 3.5;
  const auto path = hub::log::current_file();
  std::ifstream in(path);
  std::string last;
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty()) last = line;
  }
  check(last.find("answer=42 pi=3.5") != std::string::npos, "values concatenated",
        last);
  check(last.find("[DEBUG]") != std::string::npos, "debug tag", last);
}

}  // namespace

int main() {
  std::cout << "hub_log unit tests\n";
  test_level_tag_and_parse();
  test_format_line();
  test_level_filter();
  test_file_rotation();
  test_directory_empty_disables_file();
  test_concurrent_write();
  test_stream_macro();
  std::cout << "\npassed=" << g_passed << " failed=" << g_failed << '\n';
  return g_failed == 0 ? 0 : 1;
}
