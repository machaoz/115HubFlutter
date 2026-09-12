# system —— 系统能力（单实例锁 / OS 信息 / 标准路径）
add_library(hub_system STATIC
  src/single_instance.cpp
  src/sys_info.cpp
  src/paths.cpp
)

target_include_directories(hub_system PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(hub_system PUBLIC hub_baselib)

if(WIN32)
  target_link_libraries(hub_system PUBLIC shell32 ole32)
endif()

hub_apply_common(hub_system)
