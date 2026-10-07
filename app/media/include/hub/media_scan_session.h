// hub/media_scan_session.h —— 会话式媒体扫描（进度可取、可暂停/恢复/取消）
//
// 【为什么需要会话】
// 一段式 hub_media_scan 是「发起 → 阻塞 → 拿全量」，大目录一扫十几秒，
// UI 只能干等。会话把扫描搬进后台线程，调用方随时可以：
//   * progress() 拿「已发现多少文件 / 正在哪个目录」（驱动进度条）；
//   * pause()/resume() 暂停与继续（暂停实现：在 file_scan 的进度回调里
//     睡在条件变量上 —— 回调被库内部互斥串行化，睡住一个回调即全线暂停，
//     磁盘遍历自然停摆，恢复后从断点继续，不重扫）；
//   * cancel() 提前终止（丢弃结果）。
//
// 线程契约：
//   * 一个会话同一时刻只被一个线程驱动（Dart 侧由单个轮询器保证）；
//   * progress()/finished() 可随时调用；take_entries() 仅在结束后调用一次；
//   * close 之后会话 id 立即失效，再访问按「会话不存在」返回。
#ifndef HUB_MEDIA_SCAN_SESSION_H_
#define HUB_MEDIA_SCAN_SESSION_H_

#include "hub/media_scan.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace hub::media {

enum class ScanSessionState {
  kRunning,    // 扫描中
  kPaused,     // 已暂停（可 resume）
  kDone,       // 正常结束（结果可取）
  kCancelled,  // 被取消（结果不可取）
  kError,      // 失败（root 不存在/IO 异常）
};

struct ScanSessionProgress {
  ScanSessionState state = ScanSessionState::kRunning;
  int64_t files = 0;        // 已发现的视频文件数
  std::string current_dir;  // 最近遍历目录（UTF-8，'/' 分隔；可为空）
};

class ScanSession {
 public:
  /// 启动后台扫描线程。root 为空或不是目录时返回 nullptr（同步可判定的
  /// 参数错误不进线程）。
  static std::unique_ptr<ScanSession> start(const std::string& root_utf8,
                                            const ScanOptions& opt);

  /// 未结束的会话析构时自动取消并等待线程退出（不悬挂、不泄漏）
  ~ScanSession();

  ScanSession(const ScanSession&) = delete;
  ScanSession& operator=(const ScanSession&) = delete;

  void pause();
  void resume();
  void cancel();
  ScanSessionProgress progress() const;
  bool finished() const;

  /// 仅 finished() 后可取；结果保留至会话销毁（close）—— 两段式缓冲协议会
  /// 先探容量再取数，take 必须可重复，不能用 move-once 语义
  std::vector<ScanEntry> take_entries(ScanStatus* status_out);

 private:
  ScanSession() = default;
  void run(std::string root_utf8, ScanOptions opt);

  mutable std::mutex data_mu_;   // 保护 files_ / current_dir_ / done_ / status_ / entries_
  std::mutex pause_mu_;          // 暂停等待（与数据锁分离，暂停时进度仍可读）
  std::condition_variable pause_cv_;
  std::atomic<bool> paused_{false};
  std::atomic<bool> cancel_{false};
  std::atomic<bool> user_cancelled_{false};  // 区分「用户取消」与「达到条数上限」

  int64_t files_ = 0;
  std::string current_dir_;
  bool done_ = false;
  ScanStatus status_ = kOk;
  std::vector<ScanEntry> entries_;
  std::thread worker_;
};

/// 会话表：hub_api 的 C 面与对象世界之间的薄桥（id > 0 有效）
namespace session {

/// 启动会话；成功返回会话 id（>0），参数非法/目录不存在返回负错误码
int32_t start(const std::string& root_utf8, const ScanOptions& opt);
bool pause(int32_t id);
bool resume(int32_t id);
bool cancel(int32_t id);
/// false = 会话不存在
bool progress(int32_t id, ScanSessionProgress* out);
/// false = 会话不存在；*status_out 回填 kOk / kIo（未结束时为 kOk）
bool finished(int32_t id, ScanStatus* status_out);
/// 取走结果；会话不存在/未结束/已取过返回空（终态经 finished() 查询）
std::vector<ScanEntry> take(int32_t id, ScanStatus* status_out);
/// 关闭并销毁会话；id 不存在时静默（幂等）
void close(int32_t id);

}  // namespace session

}  // namespace hub::media

#endif  // HUB_MEDIA_SCAN_SESSION_H_
