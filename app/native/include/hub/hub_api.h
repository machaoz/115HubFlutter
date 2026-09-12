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

// ---- 解析（baselib 模块）----
// 解析 magnet 链接：成功把 40 位 infohash 写入 out_hex41，返回 40；失败返回负错误码
int32_t hub_parse_magnet_infohash(const char* uri, char* out_hex41);

// 解析 115:// 秒传链接 sha1：成功返回 40，失败返回负错误码
int32_t hub_parse_pan115_sha1(const char* uri, char* out_hex41);

// ---- 网络（network 模块）----
// host 级限流：返回需等待毫秒数（0 = 立即）
int32_t hub_net_rate_acquire(const char* host, int32_t min_interval_ms);

// ---- 长任务占位（vNext）----
// 大文件 SHA-1：首版未实现（返回 HUB_ERR_NOT_IMPLEMENTED），接口位保留给秒传校验
typedef void (*hub_progress_cb)(int64_t done, int64_t total);
int32_t hub_sha1_file(const char* path, char* out_hex41, hub_progress_cb progress);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // HUB_API_H_
