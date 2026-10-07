#include "file_scan/file_scan.h"
#include "file_scan/version.h"

#include <iostream>
#include <map>
#include <string>

int main(int argc, char* argv[]) {
    std::string dir = (argc > 1) ? argv[1] : ".";

    file_scan::FileScanner scanner;
    // 演示自定义类型扩展
    scanner.detector().register_extension("smi", file_scan::FileType::Text);

    file_scan::ScanOptions opts;
    opts.recursive      = true;
    opts.include_hidden = false;

    std::cout << "FileScan v" << file_scan::version::string() << "\n";
    std::cout << "Scanning: " << dir << "\n";

    std::map<std::string, int> count;
    std::uintmax_t total = 0;
    auto files = scanner.scan(dir, opts, [&](const file_scan::FileInfo& f) {
        count[file_scan::to_string(f.type)]++;
        total += f.size;
    });

    std::cout << "Total files: " << files.size() << "\n";
    std::cout << "Total size:  " << total << " bytes\n\n";
    std::cout << "By type:\n";
    for (auto& kv : count)
        std::cout << "  " << kv.first << ": " << kv.second << "\n";

    // 演示索引生成与加载（JSON Lines，流式写入）
    std::string idx = dir + "/.file_scan_index.jsonl";
    if (scanner.build_index(dir, idx, opts)) {
        std::cout << "\nIndex written to " << idx << "\n";
        auto loaded = scanner.load_index(idx);
        std::cout << "Loaded " << loaded.size() << " entries from index.\n";
    } else {
        std::cerr << "Failed to write index.\n";
    }

    // 演示导出标准 JSON（数组 + summary）：
    // 单条记录含 directory / name / extension / type / size / modified_time
    std::string jall = dir + "/file_scan_export.json";
    if (scanner.export_json(dir, jall, opts)) {
        std::cout << "\nJSON export written to " << jall << "\n";
    } else {
        std::cerr << "Failed to write JSON export.\n";
    }

    // 演示“搜索后导出”：仅视频（include_types 过滤条件作用于导出）
    file_scan::ScanOptions vopts = opts;
    vopts.include_types = {file_scan::FileType::Video};
    std::string jvid = dir + "/file_scan_videos.json";
    if (scanner.export_json(dir, jvid, vopts)) {
        std::cout << "Videos-only JSON written to " << jvid << "\n";
    }

    // 另一种用法：对内存结果先过滤再导出
    auto videos = file_scan::filter_by_type(files, file_scan::FileType::Video);
    std::string jmem = dir + "/file_scan_videos_mem.json";
    if (file_scan::write_json(videos, jmem)) {
        std::cout << "Filtered JSON written to " << jmem << " ("
                  << videos.size() << " videos)\n";
    }

    return 0;
}
