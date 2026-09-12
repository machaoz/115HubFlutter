# 115HubFlutter · project

115 会员本地资源聚合 Hub（Flutter Windows 桌面版）——源码与构建工程。

## 目录结构

```
project/
├── lunch / lunch.bat     构建编排入口（bash / cmd 转发）
├── CMakeLists.txt        原生构建根（baselib/network/system → hub_native.dll）
├── app/
│   ├── baselib/          基础组件库：日志、字符串工具、magnet/115:// 解析
│   ├── network/          原生网络能力：host 限流器、探测桩（业务网络在 gui/dio）
│   ├── system/           系统能力：单实例锁、OS 信息、AppData 路径
│   ├── native/           FFI 汇聚层：hub_api.h（唯一 C ABI）→ hub_native.dll + 冒烟
│   └── gui/              Flutter 应用（feature-first：core/sources/features/ui）
├── cmake/                构建公共件（hub_utils.cmake：统一编译选项/输出目录）
├── .cache/               编译中间产物（gitignore）
├── debug/                debug 产物：Magnetic115Hub/（gitignore）
└── release/              release 产物：Magnetic115Hub/（gitignore）
```

## 构建命令

| 命令 | 作用 |
|---|---|
| `./lunch all` | 全量编译打包（默认 **debug**）→ `debug/Magnetic115Hub/` |
| `./lunch all --release` | 全量编译打包（release）→ `release/Magnetic115Hub/` |
| `./lunch gui` / `./lunch gui --release` | 只构建 gui 模块（Flutter） |
| `./lunch baselib` `network` `system` | 独立构建原生模块（自动带依赖） |
| `./lunch native` | 构建全部原生模块 + hub_native.dll 并跑冒烟 |
| `./lunch clean` / `distclean` | 清理中间产物 / 全部产物 |

工具链：MSVC 优先（自动经 vswhere + vcvars 导入环境），回退 MinGW（仅原生模块）。
强制指定：`HUB_TOOLCHAIN=msvc` 或 `mingw`。

## 设计文档

见 `../docs/`：《概要设计说明书.md》《系统框架设计.md》《需求分析报告.md》《盘点与规划.md》

## 规矩（别破）

1. `app/` 下新增模块先在《概要设计》§3 登记
2. `app/native/hub_api.h` 是 C++ 侧唯一导出面，改动走 ADR
3. `.cache/ debug/ release/` 永不入库
4. 双端迁移 SQL 只追加不改历史（v1–v7 原样搬运，Flutter 从 v8 起）
