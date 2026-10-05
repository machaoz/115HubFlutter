# network —— 原生网络能力（限流 / 探测桩）；业务网络在 gui/dio
add_library(hub_network STATIC
  src/rate_limiter.cpp
  src/health_probe.cpp
)

target_include_directories(hub_network PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(hub_network PUBLIC hub_baselib hub::log)

hub_apply_common(hub_network)
