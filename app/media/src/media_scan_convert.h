// media_scan_convert.h —— media 模块内部共享工具
//
// 仅供本模块 src/ 下两个实现文件（media_scan.cpp / media_scan_session.cpp）
// 复用，**不进安装面、不对外承诺**：对外契约只有 include/hub/ 下两个头。
//
// 职责：把 file_scan::FileInfo（通用文件语义）翻译成 hub::media::ScanEntry
//（媒体语义），以及构造带白名单/黑名单语义的 file_scan::ScanOptions。
#ifndef HUB_MEDIA_SCAN_CONVERT_H_
#define HUB_MEDIA_SCAN_CONVERT_H_

#include "hub/media_scan.h"

#include <file_scan/file_scan.h>

#include <filesystem>
#include <string>

namespace hub::media::detail {

/// UTF-8 字符串 -> std::filesystem::path（C++17 u8path / C++20 u8string 构造）
std::filesystem::path path_from_utf8(const std::string& s);

/// path 的 generic 形态（'/' 分隔）转 UTF-8 字符串
std::string to_utf8_path(const std::filesystem::path& p);

/// 分隔符统一成 '/'；顺带削掉结尾多余斜杠，拼接子项时不会出现 "a//b"。
/// 盘符根 "D:/" 必须保住：削成 "D:" 后 Win32 会理解成「D 盘当前目录」而非根目录。
std::string normalize_slashes(std::string p);

/// generic 路径的层级数（'/' 计数 + 末段非空修正）。
/// 深度 = 文件层级数 - 根层级数，对盘根（"D:/"）与带尾斜杠的根都成立。
int count_components(const std::string& generic_u8);

/// 视频扩展名白名单（小写、带点）。与 Dart 侧 kVideoExtensions 同表同义 ——
/// 护栏裁决：扩展名白名单必须单一来源，改表只动 media_title_parser.dart
///（Dart）并同步这里，C++ 侧不允许自行增删。
const std::vector<std::string>& video_extensions();

/// 构造 file_scan 扫描参数：白名单过滤前置（避免未知扩展触发魔数读文件 IO）、
/// 跳过回收站/系统卷信息、隐藏目录不收、自动并行。
file_scan::ScanOptions build_file_scan_options(int32_t max_depth);

/// file_scan::FileInfo -> ScanEntry。
/// mtime/size 用 GetFileAttributesExW 重取：file_scan 的 modified_time 是
/// file_clock 原始计数（epoch 随标准库实现漂移，MSVC 与 MinGW 差几十年），
/// 直接当 Unix 秒用会在双工具链下产出两套时间 —— 必须经 Win32 FILETIME 归一。
ScanEntry entry_from_file_info(const file_scan::FileInfo& f, int root_components);

}  // namespace hub::media::detail

#endif  // HUB_MEDIA_SCAN_CONVERT_H_
