# media —— 媒体能力（本地媒体目录递归扫描）
#
# 只依赖 Win32 基础 API（kernel32 默认已链入），不依赖 baselib / system / network，
# 保持零耦合：本模块未来可被播放器、索引器任意一方单独复用。
add_library(hub_media STATIC
  src/media_scan.cpp
  src/media_scan_session.cpp
)

target_include_directories(hub_media PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

# file_scan（vendored，MIT）：目录遍历与文件类型识别的执行层。
# 本模块只保留「媒体语义」：扩展名白名单、跳过系统目录、深度/条数上限、
# 进度/暂停/取消的会话化封装 —— 遍历本体不再自研。
target_link_libraries(hub_media PUBLIC file_scan::file_scan)

if(WIN32)
  # FindFirstFileW / FindNextFileW / 时间转换均来自 kernel32（工具链默认链接，
  # 此处显式写出只为表达依赖意图，不是补链接）
  target_link_libraries(hub_media PUBLIC kernel32)
endif()

# 便捷别名：上层统一用 hub::media 链接，避免命名风格割裂
add_library(hub::media ALIAS hub_media)

hub_apply_common(hub_media)
