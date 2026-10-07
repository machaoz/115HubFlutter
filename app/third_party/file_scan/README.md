# 文件探查模块 (FileScan)

本地文件探查与索引库，面向音视频播放器等应用，快速在本地目录中索引文件信息。

## 功能特性

- 多文件批量探查，递归/非递归扫描，**多目录并行扫描**
- 内置 **视频 / 音频 / 图片 / 文本** 四类文件识别，支持自定义扩展
- 双重识别：扩展名表 + 文件魔数（magic number），RIFF 容器（WAV/AVI/WebP）自动判别，
  MPEG-TS 按 188 字节同步周期验证防误判
- 生成 **JSON Lines** 索引文件，**流式写入**（低内存峰值），可持久化并跨语言消费
- **导出标准 JSON**（数组 + summary 统计），单条记录含 directory / name / size / type 等字段
- **增量索引**：对比旧索引，标注新增/修改/删除/未变，返回变更统计
- **可取消**：通过 `std::atomic<bool>` 提前终止长扫描（串行/并行均安全）
- **符号链接环保护**：`follow_symlinks` 开启时自动检测并剪除环
- **UTF-8 输出**：JSON 中所有字符串一律 UTF-8（中文路径可被 Python/JS 等正确解析）
- 异步扫描、进度回调、按类型/扩展名过滤
- 零外部依赖，仅依赖 C++17 标准库（`std::filesystem`）
- 符合 CMake 模块规范，支持 `add_subdirectory` 与 `find_package` 两种接入方式

## 变更日志

### v1.1.0（本次修改）

**缺陷修复**

| 级别 | 问题 | 影响 | 修复方式 |
|------|------|------|----------|
| 严重 | 并行扫描取消时 worker 未归还任务队列 `pending` 计数 | 取消后其余 worker 永远阻塞于 `cv.wait`，`join` 挂死 | `pop` 成功后无论是否处理都归还计数；新增回归用例 |
| 严重 | `follow_symlinks` 选项实际未生效（从未传 `follow_directory_symlink`） | MSVC 下默认配置会跟随符号链接目录，链接环导致无限递归 | 明确语义 + 环检测（见下方"行为变更"） |
| 高 | Windows 下 JSON 输出为本地 ANSI(GBK) 编码 | 中文路径无法被 Python/JS 等解析器正确读取 | 全量改用 UTF-8 输出，`load_index` 经 `u8path` 还原 |
| 高 | MPEG-TS 魔数过宽：首字节 `0x47`（'G'）即判为视频 | 大量以 'G' 开头的普通文件被误分类 | 读 256 字节并验证 `head[188]==0x47` 的 188 字节同步周期 |
| 中 | `extract_string` 对"值以转义反斜杠结尾"会越过闭引号 | 解析出多余字段内容 | 改为转义序列整体跳过的正确扫描 |

**性能优化**

| 优化项 | 说明 |
|--------|------|
| 过滤前置 | hidden → 扩展名集合 → 扩展名命中类型，全部廉价判定通过后才做魔数检测；`include_types` 过滤场景下不再对每个未知扩展文件白读一次文件头（省 IO） |
| 过滤条件预规范化 | include/exclude 扩展名预先小写规范化并入哈希集合，由逐文件 `to_lower` 线性匹配改为 O(1) 查找，消除重复字符串分配 |
| 魔数读取 | 头部读取 64 → 256 字节，与原读取同属一次系统调用，换取 TS 周期校验能力 |

**可维护性 / 新增**

| 项 | 说明 |
|----|------|
| 新增 API | `FileScanner::export_json()`、`write_json()`、`JsonExportOptions` |
| 索引格式 | JSONL 索引升级为 v2，新增 `directory` 字段；`load_index` 完全向后兼容 |
| 遍历逻辑去重 | 串行与并行分支的 ~40 行重复代码合并为共享逻辑（`entry_is_dir` / `should_descend` / `accept_entry`），消除双份实现漂移 |
| 清理 | 移除 RIFF→Unknown 死代码与重复 OggS 魔数注册；修正 MP3 魔数注释笔误 |
| 测试 | 55 → **79** 项，新增 6 组用例（JSON 导出结构、过滤导出、JSONL 往返、并行取消死锁回归、TS 误判回归、中文路径 UTF-8 往返） |
| 版本 | 1.0.0 → 1.1.0（`version.h` 与 `CMakeLists.txt` 同步） |

**行为变更（需注意）**

- `follow_symlinks=false`（默认）：符号链接一律按链接文件本身处理，不再跟随其目标目录。
  MSVC 与 libstdc++ 行为一致，且默认路径下天然免疫符号链接环。
- `follow_symlinks=true`：跟随目标，并在目录层面做 `weakly_canonical` 环检测与剪除。
- 旧版 JSONL 索引可继续被 v1.1.0 读取（`path` 为权威字段，`name`/`extension` 由其推导）。

## 开源方案

| 能力 | 方案 | 说明 |
|------|------|------|
| 文件遍历 | C++17 `std::filesystem` | 源自 Boost.Filesystem，已标准化，跨平台零依赖 |
| 类型识别 | 自实现（扩展名 + 魔数） | 参考 `libmagic`/`file` 的魔数思路，避免运行时数据库依赖 |
| 索引存储 | JSON Lines | 每行一个 JSON 对象，自实现极简序列化，易被其他语言消费 |
| 结果导出 | 标准 JSON 数组 + summary | 流式写入、内存峰值 O(1)，任何 JSON 解析器均可直接消费 |

## 目录结构

```
file_scan/
├── CMakeLists.txt              # 顶层模块配置（含安装与包导出）
├── LICENSE                     # MIT License
├── cmake/FileScanConfig.cmake.in
├── include/file_scan/
│   ├── file_info.h             # FileInfo / FileType
│   ├── type_detector.h         # 类型识别器
│   ├── file_scan.h             # FileScanner 主 API
│   └── version.h
├── src/
│   ├── file_scan.cpp
│   └── type_detector.cpp
├── tests/                      # 单元测试（零依赖自研 runner）
└── examples/                   # demo 程序
```

## CMake 集成

### 方式一：add_subdirectory（源码内嵌）

将本目录放入你的项目，然后：

```cmake
add_subdirectory(third_party/file_scan)
target_link_libraries(your_app PRIVATE file_scan::file_scan)
```

### 方式二：find_package（安装后）

先安装本模块：

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
cmake --install build --prefix /your/prefix
```

消费项目：

```cmake
find_package(FileScan REQUIRED)
target_link_libraries(your_app PRIVATE file_scan::file_scan)
```

配置选项：

| 选项 | 默认 | 说明 |
|------|------|------|
| `FILE_SCAN_BUILD_TESTS` | `ON` | 构建单元测试 |
| `FILE_SCAN_BUILD_EXAMPLES` | `ON` | 构建示例 |
| `FILE_SCAN_BUILD_SHARED` | `OFF` | 构建动态库（默认静态） |
| `FILE_SCAN_INSTALL` | `ON` | 生成安装目标 |

## API 示例

```cpp
#include <file_scan/file_scan.h>
#include <atomic>

file_scan::FileScanner scanner;

// 自定义类型扩展
scanner.detector().register_extension("smi", file_scan::FileType::Text);

file_scan::ScanOptions opts;
opts.recursive      = true;
opts.include_hidden = false;
opts.include_types  = {file_scan::FileType::Video, file_scan::FileType::Audio};
opts.num_threads    = 0;   // 0=自动(硬件并发), 1=串行

// 单目录扫描
auto files = scanner.scan("/path/to/media", opts);

// 多目录并行扫描
auto files2 = scanner.scan({"/media/movies", "/media/music", "/media/photos"}, opts);

// 生成与加载索引（流式写入）
scanner.build_index("/path/to/media", "index.jsonl", opts);
auto loaded = scanner.load_index("index.jsonl");

// 增量索引：仅对比变更，返回统计
auto diff = scanner.build_index_incremental("/path/to/media", "index.jsonl", opts);
// diff.added / diff.modified / diff.deleted / diff.unchanged

// 可取消扫描
std::atomic<bool> cancel(false);
auto fut = scanner.scan_async("/path/to/media", opts);
// ...需要时：cancel = true;
auto result = fut.get();

// 导出标准 JSON（数组 + summary，流式写入，UTF-8）
// 单条记录：directory / name / extension / type / size / modified_time
scanner.export_json("/path/to/media", "media.json", opts);
// 或：先过滤内存结果再导出（include_types / include_extensions 即搜索条件）
auto videos = scanner.scan("/path/to/media", opts);
file_scan::write_json(file_scan::filter_by_type(videos, file_scan::FileType::Video),
                      "videos.json");
```

### 导出 JSON 格式

```json
{"files":[
  {"directory":"D:/media","name":"movie.mp4","extension":".mp4","type":"video","size":1048576,"modified_time":1699000000},
  {"directory":"D:/media/music","name":"song.flac","extension":".flac","type":"audio","size":33554432,"modified_time":1699000100}
],"summary":{"total_files":2,"total_size":34603008,"by_type":{"video":1,"audio":1}}}
```

- `type` 取值：`video` / `audio` / `image` / `text` / `unknown`
- `write_json()` 可通过 `JsonExportOptions` 关闭 summary 或紧凑输出
- JSON Lines 索引（`.jsonl`）每行还额外含 `path` 与增量 `status` 字段

### API 一览

| 接口 | 说明 |
|------|------|
| `scan(dir, opts, cb, cancel)` | 单目录同步扫描 |
| `scan({dirs...}, opts, cb, cancel)` | 多目录并行扫描 |
| `scan_async(dir, opts, cb)` | 异步扫描，返回 `std::future` |
| `build_index(dir, file, opts, cancel)` | 生成 JSONL 索引（流式写入，临时文件原子替换） |
| `build_index_incremental(dir, file, opts, cancel)` | 增量索引，返回 `IndexDiff{added/modified/deleted/unchanged}` |
| `load_index(file)` | 读取索引为 `vector<FileInfo>`（兼容旧版索引） |
| `export_json(dir, file, opts, cancel)` | **扫描并导出标准 JSON**（数组 + summary，UTF-8，流式） |
| `write_json(files, file, opts)` | **将内存结果导出标准 JSON** |
| `filter_by_type(files, type)` | 按类型过滤 |
| `filter_by_extension(files, ext)` | 按扩展名过滤（自动补点、大小写不敏感） |
| `detector()` | 访问 `TypeDetector`（注册自定义扩展名 / 魔数） |

`ScanOptions` 关键字段：`recursive`、`follow_symlinks`、`include_hidden`、
`include_extensions`、`exclude_extensions`、`include_types`、`max_depth`、`num_threads`。

`TypeDetector`：`register_extension(ext, type)`、`register_magic(offset, bytes, type)`、
`set_magic_enabled(bool)`、`detect_by_extension()` / `detect_by_magic()` / `detect()`。

## 播放集成方案

本库负责"**找到并描述**"媒体（JSON 索引），播放器负责"**播放**"媒体，两者通过播放清单衔接。

**关于 `.stream` 文件**：不建议使用以 JSON 作为内容的 `.stream`——主流播放器
（VLC / MPV / PotPlayer / IINA）不解析 JSON，无法直接播放；播放器需要的是媒体数据本身，
或指向媒体的标准协议 URL。生态中已有成熟方案，按场景选用：

| 场景 | 方案 | 说明 |
|------|------|------|
| 本地播放（推荐） | `.m3u` / `.m3u8` 播放列表 | 一行一个路径，所有播放器均支持，`vlc playlist.m3u` 直接播放 |
| 媒体中心生态 | `.strm` 文件 | 内容就是一行路径或 URL，Kodi / Emby / Jellyfin / Plex 原生支持 |
| 网络流式播放 | HTTP Range 服务 | nginx / FFmpeg 提供 `Range` 支持，URL 直指本地文件，无需转码与复制 |
| 转码 / 自适应码率 | HLS（`.m3u8` + 分片）或 MPEG-DASH（`.mpd`） | 真正的流媒体协议，需媒体服务器；仅在终端算力弱或带宽多变时需要 |

**推荐做法**：`.m3u` / `.strm` 均可由本库的 JSON 索引一行一条直接转换生成（成本极低），
适合作为后续 `export_playlist()` API 扩展点；网络场景则把 JSON 中的本地路径映射为
HTTP URL 交给播放器。索引只负责搜索、排序与界面展示，播放职责交给播放器。

## 性能

基准：约 2 万文件、20 目录 × 3 层级（MinGW g++ 16.2 / 16 核 / Windows，v1.0.0 实测）：

| 操作 | 串行 | 并行(16线程) | 加速 |
|------|------|------|------|
| 扫描 | ~19,400 文件/秒 | ~34,600 文件/秒 | 1.8× |
| 索引构建 | ~11,900 文件/秒 | ~16,300 文件/秒 | 1.4× |
| 索引加载 | ~600,000 文件/秒 | — | — |

并行采用工作队列 + 条件变量动态调度子目录，扫描为 CPU+IO 混合负载，
实际加速取决于磁盘并发能力（NVMe SSD / 多盘 / Linux 通常更高）。
流式索引写入与 JSON 导出的内存峰值均只与单文件元数据相关，不随文件总数增长。

v1.1.0 优化对以下场景收益最明显（未重新跑基准，以实际测量为准）：
- 带 `include_types` / `include_extensions` 的过滤扫描：过滤前置后，无效文件不再触发
  魔数检测的文件打开与读取 IO；
- 大目录（数千扩展名候选）：过滤集合预规范化后由线性匹配改为 O(1) 哈希查找。

## 构建与测试

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build
```

## 开源许可

本项目基于 **MIT License** 开源，许可证全文见仓库根目录的 [`LICENSE`](./LICENSE)。

```
MIT License

Copyright (c) 2026 FileScan Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

**要点说明**

- 允许自由使用、复制、修改、合并、发布、分发、再授权与销售，**含商业用途**；
- 允许闭源集成与商业分发（本库零外部依赖，便于直接静态链接进商业产品）；
- 唯一义务：在源码或分发副本中保留上述版权声明与许可声明；
- 不提供任何担保，作者不对使用后果承担责任。

**第三方依赖**：本项目**零外部依赖**，仅使用 C++17 标准库（`std::filesystem`），
不引入任何第三方代码或运行时数据库，因此无额外的第三方许可声明义务。
以下项目仅作**思路参考**、未复制其代码：

| 参考项目 | 许可 | 借鉴内容 |
|----------|------|----------|
| Boost.Filesystem | BSL-1.0 | `std::filesystem` 的 API 设计思路（已由 C++17 标准收录） |
| libmagic / file(1) | BSD-2-Clause | 魔数（magic number）文件类型识别思路 |

## 备注

- v1.1.0 的缺陷修复、性能优化与行为变更详见上文[变更日志](#变更日志)。
- **UTF-8 约定**：所有 JSON/JSONL 输出中的字符串一律为 UTF-8；读取时经 `u8path`
  还原为本地路径。`FileInfo::name` 在内存中为本地编码（`path.string()`），
  跨语言处理请以 JSON 中的字段为准。
- `FileInfo::modified_time` 单位为秒，其 epoch 依赖编译器对
  `std::filesystem::file_time_type` 的实现（C++17 限制），建议仅用于同环境内的相对比较与排序。
- 魔数识别默认开启，可通过 `TypeDetector::set_magic_enabled(false)` 关闭以提升扫描速度。
- 并行模式下进度回调由库内部互斥串行化调用，回调体内无需额外加锁；
  但回调会降低并行吞吐，纯批量扫描建议不传回调。
- `num_threads=0` 自动取 `std::thread::hardware_concurrency()`；单目录且子目录少时并行收益有限。
- `export_json()` / `build_index()` 采用"临时文件 + 原子重命名"策略写入，
  中途失败不会破坏既有索引文件。
