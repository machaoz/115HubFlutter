# native —— FFI 汇聚层：链接三大模块 → hub_native.dll（C ABI 唯一导出面）
add_library(hub_native SHARED
  src/hub_api.cpp
)

target_include_directories(hub_native PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(hub_native PRIVATE hub_baselib hub_network hub_system)

# 只导出 hub_ 前缀符号，收敛 ABI 面
if(MSVC)
  set_target_properties(hub_native PROPERTIES LINK_FLAGS "/DEF:\"${CMAKE_CURRENT_SOURCE_DIR}/hub_native.def\"")
endif()
# MinGW/GCC：默认自动导出全部公共符号；后续如需收敛可换 visibility=hidden + HUB_API_EXPORT 宏

# MinGW：静态链接 GCC 运行时，产物不依赖 libgcc_s_seh-1 / libstdc++-6 / libwinpthread-1，
# 否则 Flutter 单 exe 分发时必须额外携带这三个 DLL
if(MINGW)
  target_link_options(hub_native PRIVATE -static-libgcc -static-libstdc++ -static)
endif()

hub_apply_common(hub_native)

# ---- 原生冒烟程序：验证 dll 导出面可用（lunch native 后自动运行）----
add_executable(hub_native_smoke smoke/main.cpp)
target_link_libraries(hub_native_smoke PRIVATE hub_native)
hub_apply_common(hub_native_smoke)
