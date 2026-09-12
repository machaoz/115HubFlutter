# 115HubFlutter 原生构建根：聚合 baselib / network / system / native(hub_native.dll)
cmake_minimum_required(VERSION 3.24)

project(hub_native
  VERSION 1.0.0
  DESCRIPTION "115HubFlutter native layer (baselib/network/system)"
  LANGUAGES CXX)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
include(hub_utils)

# 模块登记表：新增原生模块在此登记一行，lunch 自动识别
add_subdirectory(app/baselib)
add_subdirectory(app/network)
add_subdirectory(app/system)
add_subdirectory(app/native)
