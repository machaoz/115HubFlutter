# hub_utils.cmake —— 编译公共件：统一编译选项与输出目录
# 规则：模块 CMakeLists 只 add_library(target ...) + hub_apply_common(<target>)，不重复写选项

# 统一 C++ 标准
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# 输出目录统一收敛（构建树内；拷贝到 debug/release 由 lunch 负责）
if(NOT HUB_OUTPUT_DIR)
  set(HUB_OUTPUT_DIR ${CMAKE_BINARY_DIR})
endif()

function(hub_apply_common target)
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4 /utf-8 /permissive-)
    target_compile_definitions(${target} PRIVATE _CRT_SECURE_NO_WARNINGS UNICODE _UNICODE)
    if(CMAKE_BUILD_TYPE STREQUAL "Release")
      target_compile_options(${target} PRIVATE /O2 /Zc:inline)
    endif()
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
    if(CMAKE_BUILD_TYPE STREQUAL "Release")
      target_compile_options(${target} PRIVATE -O2)
    endif()
  endif()
  set_target_properties(${target} PROPERTIES
    ARCHIVE_OUTPUT_DIRECTORY ${HUB_OUTPUT_DIR}
    LIBRARY_OUTPUT_DIRECTORY ${HUB_OUTPUT_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${HUB_OUTPUT_DIR})
endfunction()
