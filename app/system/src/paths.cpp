#include "hub/system/paths.h"

#include <shlobj.h>
#include <windows.h>

#include <cstdlib>

namespace hub::system {

namespace {

std::string known_dir(REFKNOWNFOLDERID id) {
  PWSTR p = nullptr;
  std::string out;
  if (SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &p)) && p != nullptr) {
    int len = WideCharToMultiByte(CP_UTF8, 0, p, -1, nullptr, 0, nullptr, nullptr);
    if (len > 0) {
      out.resize(static_cast<size_t>(len));
      WideCharToMultiByte(CP_UTF8, 0, p, -1, out.data(), len, nullptr, nullptr);
      if (!out.empty() && out.back() == '\0') out.pop_back();
    }
    CoTaskMemFree(p);
  }
  return out;
}

}  // namespace

std::string app_data_dir() { return known_dir(FOLDERID_RoamingAppData) + "\\Magnetic115Hub"; }

std::string app_log_dir() {
  return known_dir(FOLDERID_LocalAppData) + "\\Magnetic115Hub\\logs";
}

bool ensure_dir(const std::string& path) {
  if (path.empty()) return false;
  std::wstring w(path.begin(), path.end());
  DWORD attr = GetFileAttributesW(w.c_str());
  if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) return true;
  // 逐级创建
  std::wstring cur;
  for (size_t i = 0; i < w.size(); ++i) {
    cur.push_back(w[i]);
    if (w[i] == L'\\' && i > 1) {
      CreateDirectoryW(cur.c_str(), nullptr);
    }
  }
  BOOL ok = CreateDirectoryW(w.c_str(), nullptr);
  return ok || GetLastError() == ERROR_ALREADY_EXISTS;
}

}  // namespace hub::system
