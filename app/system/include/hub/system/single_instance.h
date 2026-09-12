// hub/system/single_instance.h —— 单实例锁（命名互斥体；避免启动两份进程同时写 hub.db）
#pragma once

#include <string>

namespace hub::system {

class SingleInstance {
 public:
  explicit SingleInstance(const std::string& name);
  ~SingleInstance();

  SingleInstance(const SingleInstance&) = delete;
  SingleInstance& operator=(const SingleInstance&) = delete;

  // 尝试持有互斥体；false = 已有实例在运行
  bool try_lock();

  // 是否为本进程持有
  bool owned() const { return owned_; }

 private:
  std::string name_;
  void* handle_;  // HANDLE，避免在公共头暴露 windows.h
  bool owned_ = false;
};

}  // namespace hub::system
