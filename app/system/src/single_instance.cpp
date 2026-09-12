#include "hub/system/single_instance.h"

#include <windows.h>

namespace hub::system {

SingleInstance::SingleInstance(const std::string& name)
    : name_("Local\\" + name), handle_(nullptr) {}

SingleInstance::~SingleInstance() {
  if (handle_ != nullptr) {
    CloseHandle(static_cast<HANDLE>(handle_));
    handle_ = nullptr;
  }
}

bool SingleInstance::try_lock() {
  if (owned_) return true;
  if (handle_ != nullptr) return false;
  HANDLE h = CreateMutexW(nullptr, TRUE, std::wstring(name_.begin(), name_.end()).c_str());
  if (h == nullptr) return false;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    CloseHandle(h);
    return false;
  }
  handle_ = h;
  owned_ = true;
  return true;
}

}  // namespace hub::system
