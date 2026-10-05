# system —— 系统能力（单实例锁 / OS 信息 / 标准路径 / 系统级密钥保护）
add_library(hub_system STATIC
  src/single_instance.cpp
  src/sys_info.cpp
  src/paths.cpp
  src/secret.cpp
)

target_include_directories(hub_system PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(hub_system PUBLIC hub_baselib)

if(WIN32)
  # crypt32：DPAPI（CryptProtectData/CryptUnprotectData）所在系统库
  target_link_libraries(hub_system PUBLIC shell32 ole32 crypt32)
endif()

hub_apply_common(hub_system)
