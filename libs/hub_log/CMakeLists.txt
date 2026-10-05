# hub_log —— 独立日志模块
#
# 两种使用方式：
#   1) 单独编译（自带测试）：  cmake -S libs/hub_log -B build/hub_log && cmake --build build/hub_log && ctest --test-dir build/hub_log
#   2) 被上层聚合（只导出 target）： add_subdirectory(libs/hub_log)
cmake_minimum_required(VERSION 3.24)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(hub_log
    VERSION 1.0.0
    DESCRIPTION "Minimal dependency-free logging library for Magnetic115Hub"
    LANGUAGES CXX)
  set(HUB_LOG_STANDALONE TRUE)
endif()

if(HUB_LOG_STANDALONE)
  set(CMAKE_CXX_STANDARD 17)
  set(CMAKE_CXX_STANDARD_REQUIRED ON)
  set(CMAKE_CXX_EXTENSIONS OFF)
  option(HUB_LOG_BUILD_TESTS "构建 hub_log 单元测试" ON)
  enable_testing()
else()
  option(HUB_LOG_BUILD_TESTS "构建 hub_log 单元测试" OFF)
endif()

add_library(hub_log STATIC
  src/logger.cpp
)

target_include_directories(hub_log PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
set_target_properties(hub_log PROPERTIES POSITION_INDEPENDENT_CODE ON)

if(MSVC)
  target_compile_options(hub_log PRIVATE /W4 /utf-8 /permissive-)
  target_compile_definitions(hub_log PRIVATE _CRT_SECURE_NO_WARNINGS UNICODE _UNICODE)
else()
  target_compile_options(hub_log PRIVATE -Wall -Wextra -Wpedantic)
endif()

if(WIN32)
  set_target_properties(hub_log PROPERTIES PREFIX "")
endif()

# 便捷别名：上层可用 hub::log 链接，避免命名风格割裂
add_library(hub::log ALIAS hub_log)

# ------------------------------------------------------------------ 单元测试
if(HUB_LOG_BUILD_TESTS)
  add_executable(hub_log_tests tests/test_logger.cpp)
  target_link_libraries(hub_log_tests PRIVATE hub_log)
  if(MSVC)
    target_compile_options(hub_log_tests PRIVATE /W4 /utf-8 /permissive-)
    target_compile_definitions(hub_log_tests PRIVATE _CRT_SECURE_NO_WARNINGS)
  else()
    target_compile_options(hub_log_tests PRIVATE -Wall -Wextra -Wpedantic)
  endif()
  set_target_properties(hub_log_tests PROPERTIES
    PREFIX ""
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})

  add_test(NAME hub_log_tests COMMAND hub_log_tests)
endif()
