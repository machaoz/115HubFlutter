// hub/baselib/magnet_util.h —— magnet/infohash/115:// 解析（纯计算，无 IO）
#pragma once

#include <optional>
#include <string>

namespace hub::baselib {

struct MagnetInfo {
  std::string infohash;  // 40 位十六进制小写；秒传场景为 sha1
  std::string name;      // dn 字段（URL 解码后的原始值，UTF-8）
};

// 解析 magnet:?xt=urn:btih:<hash>&dn=<name>...
// 兼容：40位十六进制哈希、32位 base32 哈希（转为40位hex）
std::optional<MagnetInfo> parse_magnet(const std::string& uri);

// 解析 115://<sha1>|<size>|<name> 秒传链接，返回 sha1（40位hex小写）
std::optional<std::string> parse_pan115_sha1(const std::string& uri);

// 判断字符串是否为合法 40 位十六进制 infohash
bool is_infohash_40(const std::string& s);

}  // namespace hub::baselib
