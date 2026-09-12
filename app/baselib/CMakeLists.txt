# baselib —— 基础组件库（日志 / 字符串 / magnet 解析 / 版本）
add_library(hub_baselib STATIC
  src/version.cpp
  src/logger.cpp
  src/string_util.cpp
  src/magnet_util.cpp
)

target_include_directories(hub_baselib PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

if(WIN32)
  target_link_libraries(hub_baselib PUBLIC)  # 纯用户态，无需系统库
endif()

hub_apply_common(hub_baselib)
