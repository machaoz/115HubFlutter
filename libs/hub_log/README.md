# hub_log

从 `app/baselib` 剥离出来的独立日志模块：**零第三方依赖**、**C++17**、**可单独编译**、**可单测**。

## 为什么独立

原来 `baselib/logger.h` 只有 `fprintf(stderr, ...)`，没有文件落地、没有轮转，也没法脱离 baselib 单独验证。
现在它自己是一个模块：上层项目只是它的一个"客户"。

## 单独编译 + 跑测试

```bash
cmake -S libs/hub_log -B build/hub_log
cmake --build build/hub_log --config Debug
ctest --test-dir build/hub_log --output-on-failure
```

也可以直接跑测试程序：

```bash
./build/hub_log/hub_log_tests        # 退出码 0 表示全通过
```

## 被上层聚合

```cmake
add_subdirectory(libs/hub_log)
target_link_libraries(hub_network PRIVATE hub::log)
```

## 用法

```cpp
#include "hub/log/logger.h"

hub::log::Options opt;
opt.directory = R"(C:\Program Files\Magnetic115Hub\.log)";  // 为空则不落文件
opt.prefix = "hub";
opt.max_file_bytes = 2 * 1024 * 1024;   // 单文件上限，超出即轮转
opt.keep_files = 3;                     // 含当前文件在内保留 3 份
opt.min_level = hub::log::Level::Debug;
hub::log::configure(opt);

HUB_LOG_INFO()  << "115 login start";
HUB_LOG_WARN()  << "retry " << n;
HUB_LOG_ERROR() << "db open failed: " << msg;
```

输出样例：

```
[2026-09-15 16:42:29.318][INFO ][tid=12345] 115 login start
```

## 设计要点

| 项 | 说明 |
| --- | --- |
| 级别 | `Debug / Info / Warn / Error`，低于 `min_level` 的日志**不产生任何字符串拼接** |
| sink | 抽象 `Sink`，默认 stderr；文件 sink 按目录 + 日期生成 `<prefix>-<YYYYMMDD>.log` |
| 轮转 | 单文件超过 `max_file_bytes` → `.1 / .2 …`，超出 `keep_files` 的历史删除 |
| 线程安全 | 级别用 atomic 读取（无锁），写文件用 mutex 串行化，实测 8 线程 × 200 行不丢不串行 |
| 容错 | 目录不可写 / 抛异常一律降级到"没这个功能"，不拖垮调用方；丢弃条数可从 `dropped()` 读到 |
| 可测 | `format_line()` 是纯函数；sink 可替换为任意实现（含内存 sink） |

## 目录

```
include/hub/log/logger.h   # 公共 API（头文件即文档）
src/logger.cpp             # 实现
tests/test_logger.cpp      # 单元测试（自研断言，零依赖）
```
