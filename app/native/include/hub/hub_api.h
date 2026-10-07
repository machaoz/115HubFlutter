// hub/hub_api.h —— hub_native.dll 唯一 C ABI 导出面（ffigen 由此生成 Dart 绑定）
//
// 规则（继承《盘点与规划》§2.2）：
//  1. 只做纯计算/系统调用，不做业务逻辑与 IO 编排
//  2. 字符串一律 UTF-8；输出缓冲区由调用方分配
//  3. 长任务在 Dart Isolate 内调用；进度经 hub_progress_cb 回调
//  4. 返回值：0 = 成功；负数为错误码（见 hub_errno）
//  5. 本头文件改动需同步评审（属于 ADR-002 管辖）
#ifndef HUB_API_H_
#define HUB_API_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- 错误码 ----
enum hub_errno {
  HUB_OK = 0,
  HUB_ERR_INVALID_ARG = -1,
  HUB_ERR_NOT_IMPLEMENTED = -2,
  HUB_ERR_IO = -3,
  HUB_ERR_BUFFER_TOO_SMALL = -4,
};

// ---- 版本与自检 ----
// 返回 hub_native 版本串（静态存储区，无需释放），如 "1.0.0+abi.1"
const char* hub_version(void);

// 原生层自检：逐项返回能力位（bit0 baselib / bit1 network / bit2 system / bit3 sqlite-fts5）
int32_t hub_self_check(void);

// ---- 系统信息（system 模块）----
// OS 版本写入 buf（如 "10.0.26200"），返回写入长度（含 NUL）；buf 不足返回 HUB_ERR_BUFFER_TOO_SMALL
int32_t hub_sys_os_version(char* buf, int32_t len);

// 返回 AppData 根目录（%APPDATA%\Magnetic115Hub），静态缓冲，多线程只读
const char* hub_sys_app_data_dir(void);

// 单实例探测：已被其他进程持有返回 1，否则 0（本函数只探测不持有，避免冒充主进程）
int32_t hub_sys_single_instance_busy(const char* mutex_name);

// ---- 系统级密钥保护（system 模块，Windows DPAPI）----
// 语义：由操作系统按「当前用户」加密，本进程不生成也不保存密钥。
//   *out_len 为 in/out：入参是 out 的容量，出参是实际（或所需）长度。
//   成功返回 HUB_OK；容量不足返回 HUB_ERR_BUFFER_TOO_SMALL 并把所需长度写入 *out_len。
//   无该能力（非 Windows / DPAPI 失败）返回 HUB_ERR_NOT_IMPLEMENTED 或 HUB_ERR_IO。
int32_t hub_secret_protect(const uint8_t* plain, int32_t plain_len, uint8_t* out,
                           int32_t* out_len);
int32_t hub_secret_unprotect(const uint8_t* blob, int32_t blob_len, uint8_t* out,
                             int32_t* out_len);

// 后端标识写入 buf（"dpapi" / "none"），返回值同 hub_sys_os_version
int32_t hub_secret_backend(char* buf, int32_t len);

// ---- 解析（baselib 模块）----
// 解析 magnet 链接：成功把 40 位 infohash 写入 out_hex41，返回 40；失败返回负错误码
int32_t hub_parse_magnet_infohash(const char* uri, char* out_hex41);

// 解析 115:// 秒传链接 sha1：成功返回 40，失败返回负错误码
int32_t hub_parse_pan115_sha1(const char* uri, char* out_hex41);

// ---- 网络（network 模块）----
// host 级限流：返回需等待毫秒数（0 = 立即）
int32_t hub_net_rate_acquire(const char* host, int32_t min_interval_ms);

// ---- 媒体扫描（media 模块）----
// 递归扫描 [root_utf8] 下的视频文件，结果序列化为 JSON 数组写入 out。
// 两段式：先传 out=null / out_cap=0 只取所需字节数；再按该尺寸分配缓冲区取数。
//   max_depth 递归深度上限（<=0 用默认 8）；max_files 结果上限（<=0 用默认 2000）
//   *out_len 成功时 = 实际字节数（含结尾 NUL）
// 返回 HUB_OK / HUB_ERR_BUFFER_TOO_SMALL / HUB_ERR_INVALID_ARG / HUB_ERR_IO
// 输出形如：[{"path":"D:/a/b.mkv","name":"b.mkv","size":123,"mtime":169...,"depth":2}]
//   path 分隔符统一为 '/';mtime 为 Unix **秒**;depth: root 直接子项 = 1
// 跳过：目录、重解析点、以 '.' 开头的目录、$RECYCLE.BIN、System Volume Information
int32_t hub_media_scan(const char* root_utf8, int32_t max_depth, int32_t max_files,
                       char* out, int32_t out_cap, int32_t* out_len);

// ---- 媒体扫描（media 模块）：会话式（进度/暂停/恢复/取消）----
// 大目录扫描的 UI 友好形态：hub_scan_start 起后台线程返回会话 id，调用方用
// hub_scan_poll 轮询进度（state=running/paused/done/error/cancelled + files
// + 当前目录），结束用 hub_scan_result 取与 hub_media_scan 完全同构的 JSON
// 数组，hub_scan_close 释放。暂停不重扫：恢复后从断点继续。
//   * hub_scan_start：root 为空/不存在 → HUB_ERR_INVALID_ARG / HUB_ERR_IO
//   * hub_scan_poll / hub_scan_result：两段式缓冲（同 hub_media_scan）
//   * pause/resume/cancel：会话不存在 → HUB_ERR_INVALID_ARG；已结束仍可调（no-op）
//   * hub_scan_result 仅在 state=done 时有效；error/cancelled 返回对应错误码
//   * hub_scan_close 幂等；不 close 的会话由进程退出统一回收
int32_t hub_scan_start(const char* root_utf8, int32_t max_depth, int32_t max_files);
int32_t hub_scan_poll(int32_t session, char* out, int32_t out_cap, int32_t* out_len);
int32_t hub_scan_pause(int32_t session);
int32_t hub_scan_resume(int32_t session);
int32_t hub_scan_cancel(int32_t session);
int32_t hub_scan_result(int32_t session, char* out, int32_t out_cap, int32_t* out_len);
int32_t hub_scan_close(int32_t session);

// ---- 日志（hub_log 模块）----
// 初始化原生日志：
//   dir       日志目录（UTF-8），传 NULL 或空串表示只输出到 stderr
//   min_level 0=debug 1=info 2=warn 3=error
// 返回 HUB_OK；目录不可写时不失败（降级为 stderr），仍返回 HUB_OK
// 约定：Dart 侧传入「安装路径/.log」，与 Dart 侧 hub.log 落同一目录便于现场排查
int32_t hub_log_init(const char* dir, int32_t min_level);

// 写一行原生日志（level 语义同上）。Dart 侧一般不需要调用，供冒烟/自测使用
int32_t hub_log_write(int32_t level, const char* message);

// 当前正在写的日志文件绝对路径（静态缓冲）；未启用文件输出时返回空串
const char* hub_log_current_file(void);

// ---- 长任务占位（vNext）----
// 大文件 SHA-1：首版未实现（返回 HUB_ERR_NOT_IMPLEMENTED），接口位保留给秒传校验
typedef void (*hub_progress_cb)(int64_t done, int64_t total);
int32_t hub_sha1_file(const char* path, char* out_hex41, hub_progress_cb progress);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // HUB_API_H_
