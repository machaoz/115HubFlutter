#pragma once

#define FILE_SCAN_VERSION_MAJOR 1
#define FILE_SCAN_VERSION_MINOR 1
#define FILE_SCAN_VERSION_PATCH 0
#define FILE_SCAN_VERSION_STRING "1.1.0"

namespace file_scan {
namespace version {
inline int major() { return FILE_SCAN_VERSION_MAJOR; }
inline int minor() { return FILE_SCAN_VERSION_MINOR; }
inline int patch() { return FILE_SCAN_VERSION_PATCH; }
inline const char* string() { return FILE_SCAN_VERSION_STRING; }
} // namespace version
} // namespace file_scan
