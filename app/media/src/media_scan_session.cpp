// media_scan_session.cpp —— 会话式扫描实现（后台线程 + 进度 + 暂停/取消）
//
// 【暂停的实现路径】
// file_scan 的并行扫描对进度回调做库内互斥串行化：任何一个 worker 在回调里
// 睡着，其余 worker 都会堵在进回调的门口 —— 整棵遍历树自然停摆。于是暂停
// 不需要改动 file_scan：在回调里对 pause_cv_ 睡眠即可，resume 唤醒后从当前
// 断点继续（目录队列还在内存里，不重扫已扫过的目录）。cancel 用库内建的
// atomic<bool> 检查点传播，暂停中取消也能立刻醒来退出。
#include "hub/media_scan_session.h"

#include "media_scan_convert.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#include <unordered_map>
#include <utility>

namespace hub::media {

namespace {

constexpr int32_t kDefaultMaxDepth = 8;
constexpr int32_t kDefaultMaxFiles = 2000;

}  // namespace

ScanSession::~ScanSession() {
  cancel_.store(true);
  {
    std::lock_guard<std::mutex> lk(pause_mu_);
    paused_.store(false);
  }
  pause_cv_.notify_all();
  if (worker_.joinable()) worker_.join();
}

std::unique_ptr<ScanSession> ScanSession::start(const std::string& root_utf8,
                                                const ScanOptions& opt) {
  if (root_utf8.empty()) return nullptr;
  std::error_code ec;
  const auto root = detail::path_from_utf8(root_utf8);
  if (!std::filesystem::is_directory(root, ec)) return nullptr;

  auto s = std::unique_ptr<ScanSession>(new ScanSession());
  s->worker_ = std::thread(&ScanSession::run, s.get(), root_utf8, opt);
  return s;
}

void ScanSession::pause() {
  paused_.store(true);
}

void ScanSession::resume() {
  {
    std::lock_guard<std::mutex> lk(pause_mu_);
    paused_.store(false);
  }
  pause_cv_.notify_all();
}

void ScanSession::cancel() {
  user_cancelled_.store(true);
  cancel_.store(true);
  {
    std::lock_guard<std::mutex> lk(pause_mu_);
    paused_.store(false);  // 暂停中取消：先唤醒，让线程走到取消检查点
  }
  pause_cv_.notify_all();
}

ScanSessionProgress ScanSession::progress() const {
  std::lock_guard<std::mutex> lk(data_mu_);
  ScanSessionProgress p;
  if (done_) {
    if (status_ != kOk) {
      p.state = ScanSessionState::kError;
    } else {
      p.state = user_cancelled_.load() ? ScanSessionState::kCancelled
                                       : ScanSessionState::kDone;
    }
  } else {
    p.state = paused_.load() ? ScanSessionState::kPaused
                             : ScanSessionState::kRunning;
  }
  p.files = files_;
  p.current_dir = current_dir_;
  return p;
}

bool ScanSession::finished() const {
  std::lock_guard<std::mutex> lk(data_mu_);
  return done_;
}

std::vector<ScanEntry> ScanSession::take_entries(ScanStatus* status_out) {
  std::lock_guard<std::mutex> lk(data_mu_);
  if (status_out != nullptr) *status_out = status_;
  if (!done_) return {};
  return entries_;  // 拷贝：两段式协议会取两次，结果保留至 close
}

void ScanSession::run(std::string root_utf8, ScanOptions opt) {
  const int32_t max_depth = opt.max_depth > 0 ? opt.max_depth : kDefaultMaxDepth;
  const int32_t max_files = opt.max_files > 0 ? opt.max_files : kDefaultMaxFiles;
  const int root_components =
      detail::count_components(detail::normalize_slashes(root_utf8));

  file_scan::FileScanner scanner;
  scanner.detector().set_magic_enabled(false);
  const file_scan::ScanOptions fso = detail::build_file_scan_options(max_depth);

  ScanStatus st = kOk;
  std::vector<ScanEntry> out;
  out.reserve(256);

  auto cb = [&](const file_scan::FileInfo& f) {
    // 暂停：睡在回调里（file_scan 串行化回调 → 全线停摆）；取消时立刻醒来
    if (paused_.load(std::memory_order_acquire)) {
      std::unique_lock<std::mutex> lk(pause_mu_);
      pause_cv_.wait(lk, [this] {
        return !paused_.load(std::memory_order_relaxed) ||
               cancel_.load(std::memory_order_relaxed);
      });
    }
    if (cancel_.load(std::memory_order_relaxed)) return;

    ScanEntry e = detail::entry_from_file_info(f, root_components);
    std::lock_guard<std::mutex> lk(data_mu_);
    const size_t slash = e.path.find_last_of('/');
    current_dir_ =
        (slash == std::string::npos) ? std::string() : e.path.substr(0, slash);
    out.push_back(std::move(e));
    files_ = static_cast<int64_t>(out.size());
    if (static_cast<int64_t>(out.size()) >= max_files) {
      cancel_.store(true, std::memory_order_relaxed);
    }
  };

  try {
    scanner.scan(detail::path_from_utf8(root_utf8), fso, cb, &cancel_);
  } catch (...) {
    st = kIo;
  }

  std::lock_guard<std::mutex> lk(data_mu_);
  entries_ = std::move(out);
  status_ = st;
  done_ = true;
}

// --------------------------------------------------------------- 会话表

namespace session {

namespace {

std::mutex& table_mu() {
  static std::mutex m;
  return m;
}

std::unordered_map<int32_t, std::unique_ptr<ScanSession>>& table() {
  static std::unordered_map<int32_t, std::unique_ptr<ScanSession>> t;
  return t;
}

int32_t g_next_id = 1;

constexpr int32_t kNotFound = -1;

}  // namespace

int32_t start(const std::string& root_utf8, const ScanOptions& opt) {
  auto s = ScanSession::start(root_utf8, opt);
  if (s == nullptr) return kNotFound;  // 参数/目录问题，同步报错
  std::lock_guard<std::mutex> lk(table_mu());
  const int32_t id = g_next_id++;
  table()[id] = std::move(s);
  return id;
}

bool pause(int32_t id) {
  std::lock_guard<std::mutex> lk(table_mu());
  auto it = table().find(id);
  if (it == table().end()) return false;
  it->second->pause();
  return true;
}

bool resume(int32_t id) {
  std::lock_guard<std::mutex> lk(table_mu());
  auto it = table().find(id);
  if (it == table().end()) return false;
  it->second->resume();
  return true;
}

bool cancel(int32_t id) {
  std::lock_guard<std::mutex> lk(table_mu());
  auto it = table().find(id);
  if (it == table().end()) return false;
  it->second->cancel();
  return true;
}

bool progress(int32_t id, ScanSessionProgress* out) {
  std::lock_guard<std::mutex> lk(table_mu());
  auto it = table().find(id);
  if (it == table().end()) return false;
  if (out != nullptr) *out = it->second->progress();
  return true;
}

bool finished(int32_t id, ScanStatus* status_out) {
  std::lock_guard<std::mutex> lk(table_mu());
  auto it = table().find(id);
  if (it == table().end()) return false;
  if (status_out != nullptr) {
    // finished=false 时终态未定，报 kOk 仅表示「尚无失败」；调用方以
    // progress() 的 state 为准判断是否结束
    ScanSessionProgress p = it->second->progress();
    *status_out = (p.state == ScanSessionState::kError) ? kIo : kOk;
  }
  return it->second->finished();
}

std::vector<ScanEntry> take(int32_t id, ScanStatus* status_out) {
  std::lock_guard<std::mutex> lk(table_mu());
  auto it = table().find(id);
  if (it == table().end()) return {};
  return it->second->take_entries(status_out);
}

void close(int32_t id) {
  std::lock_guard<std::mutex> lk(table_mu());
  table().erase(id);  // 析构自动取消 + join；幂等
}

}  // namespace session

}  // namespace hub::media
