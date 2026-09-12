#include "hub/system/sys_info.h"

#include <windows.h>

namespace hub::system {

OsInfo os_info() {
  OsInfo info;
  // RtlGetVersion 不受兼容性垫片影响，比 GetVersionEx 可靠；用 EXW 结构以便读服务器类型
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll != nullptr) {
    // 函数指针强转在 GCC 下需抑制 -Wcast-function-type；MSVC 的 /W4 不报此项
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wcast-function-type"
#endif
    auto fn = reinterpret_cast<RtlGetVersionFn>(GetProcAddress(ntdll, "RtlGetVersion"));
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif
    if (fn != nullptr) {
      RTL_OSVERSIONINFOEXW vi{};
      vi.dwOSVersionInfoSize = sizeof(vi);
      if (fn(reinterpret_cast<PRTL_OSVERSIONINFOW>(&vi)) == 0) {
        info.major = vi.dwMajorVersion;
        info.minor = vi.dwMinorVersion;
        info.build = vi.dwBuildNumber;
        info.is_server = vi.wProductType != VER_NT_WORKSTATION;
        info.version = std::to_string(vi.dwMajorVersion) + "." +
                       std::to_string(vi.dwMinorVersion) + "." +
                       std::to_string(vi.dwBuildNumber);
        return info;
      }
    }
  }
  info.version = "unknown";
  return info;
}

std::string cpu_arch() {
#if defined(_M_ARM64) || defined(__aarch64__)
  return "arm64";
#else
  SYSTEM_INFO si{};
  GetNativeSystemInfo(&si);
  switch (si.wProcessorArchitecture) {
    case PROCESSOR_ARCHITECTURE_AMD64: return "x64";
    case PROCESSOR_ARCHITECTURE_ARM64: return "arm64";
    case PROCESSOR_ARCHITECTURE_INTEL: return "x86";
    default: return "unknown";
  }
#endif
}

}  // namespace hub::system
