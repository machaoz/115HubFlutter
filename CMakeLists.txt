# 115HubFlutter 原生构建根：聚合 baselib / network / system / native(hub_native.dll)
cmake_minimum_required(VERSION 3.24)

project(hub_native
  VERSION 1.0.0
  DESCRIPTION "115HubFlutter native layer (baselib/network/system)"
  LANGUAGES CXX)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
include(hub_utils)

# 独立子模块（可脱离本工程单独编译，自带单元测试）
add_subdirectory(libs/hub_log)

# 模块登记表：新增原生模块在此登记一行，lunch 自动识别
add_subdirectory(app/baselib)
add_subdirectory(app/network)
add_subdirectory(app/system)
add_subdirectory(app/media)
add_subdirectory(app/native)

# ---- 第三方：file_scan（MIT，vendored）----
# 文件探查执行层（ADR-0002 后继批次引入）：目录遍历/类型识别/JSON 导出统一交给它，
# hub::media 只做语义封装。测试/示例/安装目标在此工程内一律关闭 —— 只当库用。
set(FILE_SCAN_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(FILE_SCAN_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(FILE_SCAN_INSTALL        OFF CACHE BOOL "" FORCE)
add_subdirectory(app/third_party/file_scan)

# vendored 子项目自带 CMake 不认识本工程的编译约定，这里在集成点补一条：
# MSVC 下**必须** /utf-8 —— 该模块源码里到处是 UTF-8 中文注释，缺这个开关时
# cl 按当前代码页（GBK）解码，某些汉字双字节尾字节恰好是 0x5C（反斜杠），
# 会把 // 注释续行吃掉后面的代码，报出一堆「FileScanner 不是类」之类的
# 无厘头语法错误（实测 MinGW 无此问题，故只有 MSVC 链路会暴露）。
target_compile_options(file_scan
  PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
