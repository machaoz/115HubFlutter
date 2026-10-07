// hub/media_scan.h —— 媒体目录递归扫描（media 模块对外契约）
//
// 只解决一件事：**把「某个目录下有哪些视频文件」这个 IO 密集问题算清楚**。
// 标题解析（第几季第几集）留在 Dart 侧（见 ADR-0002：解析规则 ~800 行正则，
// 下沉需要 C++ 复刻并双端维护，违反「每个抽象必须自证复杂度」）。
//
// 约定：
//  1. 一切字符串 UTF-8；Win32 内部的 UTF-16 在本模块内消化，不外泄
//  2. depth：root 的直接子项为 1，往下每层 +1（root 自身算 0）
//  3. max_depth：条目最大深度上限；max_depth=1 等价于「只扫一层」
//  4. mtime：Unix **秒**（不是毫秒）—— Dart 网关负责 ×1000 转成 mtimeMs
//  5. 非 Windows 平台不支持（本工程 Windows-only），返回 kIo
#ifndef HUB_MEDIA_SCAN_H_
#define HUB_MEDIA_SCAN_H_

#include <cstdint>
#include <string>
#include <vector>

namespace hub::media {

/// 扫描结果的一条记录
struct ScanEntry {
  std::string path;   // 绝对路径，分隔符统一为 '/'
  std::string name;   // 文件名（含扩展名）
  int64_t size = 0;   // 字节
  int64_t mtime = 0;  // Unix 秒
  int32_t depth = 0;  // 见上文约定 2
};

/// 扫描参数；<=0 的分项回落到默认值（默认深度 8、默认条数 2000）
struct ScanOptions {
  int32_t max_depth = 8;
  int32_t max_files = 2000;
};

/// 与 hub_api.h 的 hub_errno 对齐的子集：0 / -1 / -3
enum ScanStatus {
  kOk = 0,
  kInvalidArg = -1,
  kIo = -3,
};

/// 深度优先（显式队列）遍历 [root_utf8]，把命中的视频文件追加进 out。
/// 跳过：目录、重解析点（符号链接/挂载点）、以 '.' 开头的目录、
///       $RECYCLE.BIN、System Volume Information、非视频扩展名。
/// root 打不开 → kIo；子目录打不开（无权限）只跳过，不算整次失败。
ScanStatus scan_directory(const std::string& root_utf8, const ScanOptions& opt,
                          std::vector<ScanEntry>* out);

/// 结果序列化为 JSON 数组（紧凑无空格）。
/// 转义覆盖 \ " 与全部控制字符（\b \f \n \r \t / \u00XX）；UTF-8 多字节原样透传。
std::string to_json_array(const std::vector<ScanEntry>& entries);

}  // namespace hub::media

#endif  // HUB_MEDIA_SCAN_H_
