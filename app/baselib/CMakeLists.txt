# baselib —— 基础组件库（字符串 / magnet 解析 / 版本）
# 日志已独立为 libs/hub_log 模块（可单独编译 + 自带单元测试），baselib 不再自带实现
add_library(hub_baselib STATIC
  src/version.cpp
  src/string_util.cpp
  src/magnet_util.cpp
)

target_include_directories(hub_baselib PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

if(WIN32)
  target_link_libraries(hub_baselib PUBLIC)  # 纯用户态，无需系统库
endif()

hub_apply_common(hub_baselib)
