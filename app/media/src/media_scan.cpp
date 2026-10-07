// media_scan.cpp —— 媒体目录递归扫描（执行层：file_scan，vendored MIT）
//
// 【v2.3 变更：遍历本体退役，语义封装保留】
// 目录遍历与文件识别改由 third_party/file_scan 承担（并行扫描、扩展名+魔数
// 双重识别、符号链接环防护、UTF-8 输出）。本文件收敛为「媒体语义封装」：
//   * 19 项视频扩展名白名单（与 Dart kVideoExtensions 同表，白名单前置免魔数 IO）
//   * 跳过 $RECYCLE.BIN / System Volume Information / 点前缀隐藏目录（旧引擎行为，
//     经 file_scan 新增的 exclude_dir_names 选项表达）
//   * 深度/条数上限；mtime 经 Win32 FILETIME 归一为 Unix 秒
//
// 【为什么 mtime 必须重取】
// file_scan::FileInfo.modified_time 取自 file_clock 原始计数，C++17 下其 epoch
// 依赖标准库实现（MSVC 自 1601 年、libstdc++ 自 2174 年起算），直接透传会让
// MinGW 与 MSVC 产物给出相差数千年的两套时间。GetFileAttributesExW 一次调用
// 同时拿回 size 与 FILETIME，对已通过扩展名过滤的少量文件开销可忽略。
//
// 【为什么路径统一正斜杠】
// 反斜杠在 JSON 里必须转义成 \\，会让每条记录膨胀且肉眼难读；统一成 '/' 后
// JSON 里几乎不出现转义序列，Dart 侧 Uri.file() 也更省心。
#include "hub/media_scan.h"

#include "media_scan_convert.h"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <utility>
#include <vector>

namespace hub::media {

namespace {

constexpr int32_t kDefaultMaxDepth = 8;
constexpr int32_t kDefaultMaxFiles = 2000;

/// FILETIME 是 1601-01-01 起的 100ns 计数；Unix epoch 与之差 11644473600 秒
int64_t filetime_to_unix(const FILETIME& ft) {
  ULARGE_INTEGER ul;
  ul.LowPart = ft.dwLowDateTime;
  ul.HighPart = ft.dwHighDateTime;
  if (ul.QuadPart == 0) return 0;
  return static_cast<int64_t>(ul.QuadPart / 10000000ULL) - 11644473600LL;
}

/// JSON 字符串转义。UTF-8 多字节序列的每个字节都 >= 0x80，
/// 走 default 分支原样透传，不会被误伤成控制字符。
void append_json_string(std::string* out, const std::string& s) {
  out->push_back('"');
  for (unsigned char c : s) {
    switch (c) {
      case '"': *out += "\\\""; break;
      case '\\': *out += "\\\\"; break;
      case '\b': *out += "\\b"; break;
      case '\f': *out += "\\f"; break;
      case '\n': *out += "\\n"; break;
      case '\r': *out += "\\r"; break;
      case '\t': *out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
          *out += buf;
        } else {
          out->push_back(static_cast<char>(c));
        }
        break;
    }
  }
  out->push_back('"');
}

}  // namespace

namespace detail {

std::filesystem::path path_from_utf8(const std::string& s) {
#if defined(__cpp_lib_char8_t)
  return std::filesystem::path(std::u8string(s.begin(), s.end()));
#else
  return std::filesystem::u8path(s);
#endif
}

std::string to_utf8_path(const std::filesystem::path& p) {
#if defined(__cpp_lib_char8_t)
  const auto u8 = p.generic_u8string();
  return std::string(u8.begin(), u8.end());
#else
  return p.generic_u8string();
#endif
}

std::string normalize_slashes(std::string p) {
  std::replace(p.begin(), p.end(), '\\', '/');
  while (p.size() > 1 && p.back() == '/' && p[p.size() - 2] != ':') {
    p.pop_back();
  }
  return p;
}

int count_components(const std::string& generic) {
  if (generic.empty()) return 0;
  int n = 0;
  for (char c : generic) {
    if (c == '/') ++n;
  }
  if (generic.back() != '/') ++n;
  return n;
}

const std::vector<std::string>& video_extensions() {
  static const std::vector<std::string> kExts = {
      ".mp4", ".mkv",  ".avi", ".mov", ".wmv", ".flv", ".ts",
      ".m2ts", ".m4v", ".webm", ".rmvb", ".rm", ".mpg", ".mpeg",
      ".3gp", ".ogv", ".vob", ".mts", ".divx"};
  return kExts;
}

file_scan::ScanOptions build_file_scan_options(int32_t max_depth) {
  file_scan::ScanOptions o;
  o.recursive = true;
  o.include_hidden = false;  // 点前缀目录/文件一律不收（与 Dart 回退同规则）
  o.include_extensions = video_extensions();
  o.exclude_dir_names = {"$RECYCLE.BIN", "System Volume Information"};
  // 深度语义与旧引擎一致：条目深度上限（root 直接子项 = 1），<=0 由调用方给默认
  o.max_depth = max_depth > 0 ? static_cast<std::size_t>(max_depth) : 0;
  o.num_threads = 0;  // 自动取硬件并发
  return o;
}

ScanEntry entry_from_file_info(const file_scan::FileInfo& f,
                               int root_components) {
  ScanEntry e;
  e.path = to_utf8_path(f.path);
  const size_t slash = e.path.find_last_of('/');
  e.name = (slash == std::string::npos) ? e.path : e.path.substr(slash + 1);
  e.depth = count_components(e.path) - root_components;
  e.size = static_cast<int64_t>(f.size);
  e.mtime = 0;
#ifdef _WIN32
  WIN32_FILE_ATTRIBUTE_DATA ad;
  if (GetFileAttributesExW(f.path.c_str(), GetFileExInfoStandard, &ad) != 0) {
    e.size = static_cast<int64_t>(
        (static_cast<uint64_t>(ad.nFileSizeHigh) << 32) |
        static_cast<uint64_t>(ad.nFileSizeLow));
    e.mtime = filetime_to_unix(ad.ftLastWriteTime);
  }
#endif
  return e;
}

}  // namespace detail

std::string to_json_array(const std::vector<ScanEntry>& entries) {
  std::string s;
  s.reserve(entries.size() * 160);
  s += '[';
  for (size_t i = 0; i < entries.size(); ++i) {
    if (i != 0) s += ',';
    const ScanEntry& e = entries[i];
    s += "{\"path\":";
    append_json_string(&s, e.path);
    s += ",\"name\":";
    append_json_string(&s, e.name);
    s += ",\"size\":";
    s += std::to_string(e.size);
    s += ",\"mtime\":";
    s += std::to_string(e.mtime);
    s += ",\"depth\":";
    s += std::to_string(e.depth);
    s += '}';
  }
  s += ']';
  return s;
}

ScanStatus scan_directory(const std::string& root_utf8, const ScanOptions& opt,
                          std::vector<ScanEntry>* out) {
  if (out == nullptr) return kInvalidArg;
  out->clear();
  if (root_utf8.empty()) return kInvalidArg;

#ifdef _WIN32
  const std::filesystem::path root_path = detail::path_from_utf8(root_utf8);
  std::error_code ec;
  if (!std::filesystem::is_directory(root_path, ec)) return kIo;

  const int32_t max_depth = opt.max_depth > 0 ? opt.max_depth : kDefaultMaxDepth;
  const int32_t max_files = opt.max_files > 0 ? opt.max_files : kDefaultMaxFiles;
  const int root_components =
      detail::count_components(detail::normalize_slashes(root_utf8));

  file_scan::FileScanner scanner;
  scanner.detector().set_magic_enabled(false);  // 白名单已覆盖，魔数读头纯浪费
  const file_scan::ScanOptions fso = detail::build_file_scan_options(max_depth);

  std::atomic<bool> cancel{false};
  std::vector<ScanEntry> collected;
  collected.reserve(256);
  auto cb = [&](const file_scan::FileInfo& f) {
    if (static_cast<int64_t>(collected.size()) >= max_files) {
      cancel.store(true);
      return;
    }
    collected.push_back(detail::entry_from_file_info(f, root_components));
  };

  try {
    // 并行扫描（num_threads=0）；回调由 file_scan 内部互斥串行化，收集无竞争
    scanner.scan(root_path, fso, cb, &cancel);
  } catch (...) {
    return kIo;  // 遍历抛异常按 IO 失败处理，不向上泄漏
  }
  // 命中上限后到遍历停止之间可能再多回几条，按上限裁齐
  if (static_cast<int64_t>(collected.size()) > max_files) {
    collected.resize(static_cast<size_t>(max_files));
  }
  *out = std::move(collected);
  return kOk;
#else
  // 非 Windows：本工程不支持，返回 IO 而不是伪装成功
  (void)opt;
  return kIo;
#endif
}

}  // namespace hub::media
