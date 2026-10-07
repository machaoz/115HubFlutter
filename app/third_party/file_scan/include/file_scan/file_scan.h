#pragma once

#include "file_scan/file_info.h"
#include "file_scan/type_detector.h"
#include <atomic>
#include <cstddef>
#include <filesystem>
#include <functional>
#include <future>
#include <string>
#include <vector>

namespace file_scan {

struct ScanOptions {
    bool   recursive        = true;
    bool   follow_symlinks  = false;
    bool   include_hidden   = false;
    std::vector<std::string> include_extensions;  // 空=全部（小写，含点）
    std::vector<std::string> exclude_extensions;  // 排除（小写，含点）
    std::vector<FileType>    include_types;       // 空=全部
    // 目录名黑名单（精确匹配，如 "$RECYCLE.BIN"）：命中不递归也不收录。
    // 播放器场景用于跳过回收站/系统卷信息等必然无媒体且常不可读的目录。
    std::vector<std::string> exclude_dir_names;
    std::size_t max_depth    = 0;                 // 0=无限
    std::size_t num_threads  = 0;                 // 0=自动(硬件并发), 1=串行
};

// JSON 导出选项（write_json / export_json）
struct JsonExportOptions {
    bool include_summary = true;   // 尾部附加 {"summary":{...}} 统计对象
    bool pretty          = true;   // 每个条目独占一行（整体仍是合法 JSON）
};

struct IndexDiff {
    std::size_t added     = 0;
    std::size_t modified  = 0;
    std::size_t deleted   = 0;
    std::size_t unchanged = 0;
};

using ProgressCallback = std::function<void(const FileInfo&)>;

class FileScanner {
public:
    FileScanner();
    explicit FileScanner(TypeDetector detector);
    ~FileScanner();

    FileScanner(const FileScanner&)            = default;
    FileScanner& operator=(const FileScanner&) = default;
    FileScanner(FileScanner&&) noexcept         = default;
    FileScanner& operator=(FileScanner&&) noexcept = default;

    // 单目录同步扫描（cancel 置 true 可提前终止）
    std::vector<FileInfo> scan(const std::filesystem::path& dir,
                               const ScanOptions& opts = {},
                               ProgressCallback cb = nullptr,
                               const std::atomic<bool>* cancel = nullptr) const;

    // 多目录同步扫描（并行）
    std::vector<FileInfo> scan(const std::vector<std::filesystem::path>& dirs,
                               const ScanOptions& opts = {},
                               ProgressCallback cb = nullptr,
                               const std::atomic<bool>* cancel = nullptr) const;

    // 异步扫描
    std::future<std::vector<FileInfo>>
    scan_async(const std::filesystem::path& dir,
                const ScanOptions& opts = {},
                ProgressCallback cb = nullptr) const;

    // 生成索引（JSON Lines，流式写入，低内存峰值）
    bool build_index(const std::filesystem::path& dir,
                     const std::filesystem::path& index_file,
                     const ScanOptions& opts = {},
                     const std::atomic<bool>* cancel = nullptr) const;

    // 增量索引：对比旧索引，重写完整索引并标注每条 status，返回变更统计
    IndexDiff build_index_incremental(const std::filesystem::path& dir,
                                       const std::filesystem::path& index_file,
                                       const ScanOptions& opts = {},
                                       const std::atomic<bool>* cancel = nullptr) const;

    // 从索引加载
    std::vector<FileInfo> load_index(const std::filesystem::path& index_file) const;

    // 导出标准 JSON（数组 + summary）：扫描 dir（可带过滤条件）并流式写出。
    // 单条记录含 directory / name / extension / type / size / modified_time，
    // 字符串一律 UTF-8 编码。
    bool export_json(const std::filesystem::path& dir,
                     const std::filesystem::path& json_file,
                     const ScanOptions& opts = {},
                     const std::atomic<bool>* cancel = nullptr) const;

    const TypeDetector& detector() const;
    TypeDetector&       detector();

private:
    // 核心：多目录扫描，collect=false 时仅回调不收集（流式）
    std::vector<FileInfo> scan_impl(const std::vector<std::filesystem::path>& dirs,
                                     const ScanOptions& opts,
                                     ProgressCallback cb,
                                     const std::atomic<bool>* cancel,
                                     bool collect) const;

    TypeDetector detector_;
};

// 将扫描结果写为标准 JSON 文件：{"files":[...],"summary":{...}}（流式写入）
bool write_json(const std::vector<FileInfo>& files,
                const std::filesystem::path& json_file,
                const JsonExportOptions& opts = {});

std::vector<FileInfo> filter_by_type(const std::vector<FileInfo>& files, FileType type);
std::vector<FileInfo> filter_by_extension(const std::vector<FileInfo>& files,
                                          const std::string& ext);

} // namespace file_scan
