// hub/baselib/string_util.h —— 字符串工具（UTF-8 语义按字节处理，见各函数说明）
#pragma once

#include <string>
#include <vector>

namespace hub::baselib {

// 去除首尾空白（ASCII 空白；中文场景仅用于清洗协议字段）
std::string trim(const std::string& s);

// 按分隔符切分（不保留空段）
std::vector<std::string> split(const std::string& s, char sep);

// 大小写不敏感前缀判断（协议头如 magnet:? 、115://）
bool starts_with_icase(const std::string& s, const std::string& prefix);

// ASCII 小写化（仅用于 infohash 等十六进制/ASCII 字段，不做宽字符转换）
std::string to_lower_ascii(const std::string& s);

}  // namespace hub::baselib
