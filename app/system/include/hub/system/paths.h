// hub/system/paths.h —— 应用标准路径（AppData 等；与 Electron 版 userData 口径对齐）
#pragma once

#include <string>

namespace hub::system {

// %APPDATA%\Magnetic115Hub（Roaming）
std::string app_data_dir();

// %LOCALAPPDATA%\Magnetic115Hub\logs
std::string app_log_dir();

// 返回是否创建成功；目录存在也算成功
bool ensure_dir(const std::string& path);

}  // namespace hub::system
