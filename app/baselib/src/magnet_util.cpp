#include "hub/baselib/magnet_util.h"

#include <cstdint>

#include "hub/baselib/string_util.h"

namespace hub::baselib {

namespace {

int hex_val(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// base32 (RFC 4648) → hex，用于 32 位 btih
std::string base32_to_hex(const std::string& in) {
  static const char* kHex = "0123456789abcdef";
  uint64_t bits = 0;
  int nbits = 0;
  std::string out;
  for (char c : in) {
    int v;
    if (c >= 'A' && c <= 'Z') v = c - 'A';
    else if (c >= 'a' && c <= 'z') v = c - 'a';
    else if (c >= '2' && c <= '7') v = c - '2' + 26;
    else return {};
    bits = (bits << 5) | static_cast<uint64_t>(v);
    nbits += 5;
    if (nbits >= 4) {
      out.push_back(kHex[(bits >> (nbits - 4)) & 0xF]);
      nbits -= 4;
    }
  }
  return out;
}

std::string url_decode(const std::string& in) {
  std::string out;
  out.reserve(in.size());
  for (size_t i = 0; i < in.size(); ++i) {
    if (in[i] == '%' && i + 2 < in.size()) {
      int h = hex_val(in[i + 1]), l = hex_val(in[i + 2]);
      if (h >= 0 && l >= 0) {
        out.push_back(static_cast<char>(h * 16 + l));
        i += 2;
        continue;
      }
    }
    if (in[i] == '+') {
      out.push_back(' ');
    } else {
      out.push_back(in[i]);
    }
  }
  return out;
}

}  // namespace

bool is_infohash_40(const std::string& s) {
  if (s.size() != 40) return false;
  for (char c : s) {
    if (hex_val(c) < 0) return false;
  }
  return true;
}

std::optional<MagnetInfo> parse_magnet(const std::string& uri) {
  if (!starts_with_icase(uri, "magnet:?")) return std::nullopt;
  MagnetInfo info;
  auto parts = split(uri.substr(8), '&');
  for (const auto& p : parts) {
    if (starts_with_icase(p, "xt=urn:btih:")) {
      std::string v = to_lower_ascii(p.substr(12));
      if (v.size() == 32) v = base32_to_hex(to_lower_ascii(p.substr(12)));
      if (is_infohash_40(v)) info.infohash = v;
    } else if (starts_with_icase(p, "dn=")) {
      info.name = url_decode(p.substr(3));
    }
  }
  if (info.infohash.empty()) return std::nullopt;
  return info;
}

std::optional<std::string> parse_pan115_sha1(const std::string& uri) {
  if (!starts_with_icase(uri, "115://")) return std::nullopt;
  auto parts = split(uri.substr(6), '|');
  if (parts.empty()) return std::nullopt;
  std::string v = to_lower_ascii(parts[0]);
  if (!is_infohash_40(v)) return std::nullopt;
  return v;
}

}  // namespace hub::baselib
