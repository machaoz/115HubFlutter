// hub/baselib/version.h —— 基础组件库版本
#pragma once

#define HUB_BASELIB_VERSION_MAJOR 1
#define HUB_BASELIB_VERSION_MINOR 0
#define HUB_BASELIB_VERSION_PATCH 0

namespace hub::baselib {

inline constexpr const char* kVersion = "1.0.0";

const char* version();  // 返回 kVersion

}  // namespace hub::baselib
