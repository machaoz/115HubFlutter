#include "file_scan/file_scan.h"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include <algorithm>
#include <atomic>
#include <thread>

namespace fs = std::filesystem;

static int g_pass = 0, g_fail = 0;
#define CHECK(cond) do { if (cond) { ++g_pass; } else { ++g_fail; \
    std::printf("FAIL: %s (%s:%d)\n", #cond, __FILE__, __LINE__); } } while(0)

static void write_file(const fs::path& p, const std::string& content) {
    fs::create_directories(p.parent_path());
    std::ofstream f(p, std::ios::binary);
    f.write(content.data(), static_cast<std::streamsize>(content.size()));
}

static std::string riff(const char* fourcc) {
    std::string c;
    c.append("RIFF", 4);
    c.append(4, '\0');           // 4 字节长度占位
    c.append(fourcc, 4);
    return c;
}

static std::string read_all(const fs::path& p) {
    std::ifstream in(p, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)),
                        std::istreambuf_iterator<char>());
}

static std::size_t count_of(const std::string& hay, const std::string& needle) {
    std::size_t n = 0;
    for (std::size_t p = hay.find(needle); p != std::string::npos;
         p = hay.find(needle, p + 1)) ++n;
    return n;
}

int main() {
    fs::path tmp = fs::temp_directory_path() / "file_scan_test";
    std::error_code ec;
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp, ec);

    fs::path magic_dir = tmp / "magic";
    fs::path scan_dir  = tmp / "scan";
    fs::create_directories(magic_dir, ec);
    fs::create_directories(scan_dir, ec);

    // 1. 默认扩展名识别
    {
        file_scan::TypeDetector d;
        CHECK(d.detect_by_extension(".mp4") == file_scan::FileType::Video);
        CHECK(d.detect_by_extension("mp3")  == file_scan::FileType::Audio);
        CHECK(d.detect_by_extension(".JPG") == file_scan::FileType::Image);
        CHECK(d.detect_by_extension("txt")  == file_scan::FileType::Text);
        CHECK(d.detect_by_extension(".xyz") == file_scan::FileType::Unknown);
    }

    // 2. 自定义扩展名注册
    {
        file_scan::TypeDetector d;
        d.register_extension("myv", file_scan::FileType::Video);
        CHECK(d.detect_by_extension(".myv") == file_scan::FileType::Video);
    }

    // 3. 魔数识别（文件放在 magic_dir，不污染 scan_dir）
    {
        fs::path p = magic_dir / "jpeg.bin";
        write_file(p, std::string("\xFF\xD8\xFF\xE0", 4));
        file_scan::TypeDetector d;
        CHECK(d.detect_by_magic(p) == file_scan::FileType::Image);
    }
    {
        fs::path p = magic_dir / "flac.bin";
        write_file(p, std::string("fLaC\x00\x00\x00\x22", 8));
        file_scan::TypeDetector d;
        CHECK(d.detect_by_magic(p) == file_scan::FileType::Audio);
    }
    {
        fs::path p = magic_dir / "wav.bin";
        write_file(p, riff("WAVE") + "fmt ");
        file_scan::TypeDetector d;
        CHECK(d.detect_by_magic(p) == file_scan::FileType::Audio);
    }
    {
        fs::path p = magic_dir / "avi.bin";
        write_file(p, riff("AVI ") + "LIST");
        file_scan::TypeDetector d;
        CHECK(d.detect_by_magic(p) == file_scan::FileType::Video);
    }
    {
        fs::path p = magic_dir / "png.bin";
        write_file(p, std::string("\x89PNG\r\n\x1A\n", 8));
        file_scan::TypeDetector d;
        CHECK(d.detect_by_magic(p) == file_scan::FileType::Image);
    }

    // 4. 扫描目录（scan_dir 干净）
    write_file(scan_dir / "a.mp4", "x");
    write_file(scan_dir / "b.mp3", "x");
    write_file(scan_dir / "c.txt", "x");
    write_file(scan_dir / "d.jpg", "x");
    write_file(scan_dir / "sub" / "e.mkv", "x");
    write_file(scan_dir / ".hidden.mp4", "x");

    {
        file_scan::FileScanner s;
        file_scan::ScanOptions opts;
        auto files = s.scan(scan_dir, opts);
        CHECK(files.size() == 5);  // 不含 .hidden

        opts.include_hidden = true;
        files = s.scan(scan_dir, opts);
        CHECK(files.size() == 6);

        opts.include_hidden = false;
        opts.recursive = false;
        files = s.scan(scan_dir, opts);
        CHECK(files.size() == 4);  // 不含 sub/e.mkv
    }

    // 5. include_types
    {
        file_scan::FileScanner s;
        file_scan::ScanOptions opts;
        opts.include_types = {file_scan::FileType::Video};
        auto files = s.scan(scan_dir, opts);
        CHECK(files.size() == 2);  // a.mp4 + sub/e.mkv
        for (auto& f : files) CHECK(f.type == file_scan::FileType::Video);
    }

    // 6. include/exclude extensions
    {
        file_scan::FileScanner s;
        file_scan::ScanOptions opts;
        opts.include_extensions = {".mp3"};
        CHECK(s.scan(scan_dir, opts).size() == 1);

        file_scan::ScanOptions opts2;
        opts2.exclude_extensions = {".mp4", ".mkv"};
        auto files = s.scan(scan_dir, opts2);
        CHECK(files.size() == 3);  // mp3, txt, jpg
    }

    // 7. 索引 build/load 往返
    {
        file_scan::FileScanner s;
        fs::path idx = tmp / "index.jsonl";   // 放在 scan_dir 之外，避免污染
        CHECK(s.build_index(scan_dir, idx));
        auto loaded = s.load_index(idx);
        auto orig   = s.scan(scan_dir);
        CHECK(loaded.size() == orig.size());

        auto by_name = [](const file_scan::FileInfo& a, const file_scan::FileInfo& b) {
            return a.path.generic_string() < b.path.generic_string();
        };
        std::sort(loaded.begin(), loaded.end(), by_name);
        std::sort(orig.begin(),   orig.end(),   by_name);

        bool all_match = true;
        for (std::size_t i = 0; i < loaded.size() && i < orig.size(); ++i) {
            if (loaded[i].name != orig[i].name ||
                loaded[i].type != orig[i].type ||
                loaded[i].extension != orig[i].extension) {
                all_match = false;
                break;
            }
        }
        CHECK(all_match);
    }

    // 8. 过滤函数
    {
        file_scan::FileScanner s;
        auto files = s.scan(scan_dir);
        CHECK(file_scan::filter_by_type(files, file_scan::FileType::Video).size() == 2);
        CHECK(file_scan::filter_by_extension(files, ".mp3").size() == 1);
        CHECK(file_scan::filter_by_extension(files, "mp4").size() == 1);
    }

    // 9. 异步扫描
    {
        file_scan::FileScanner s;
        auto fut = s.scan_async(scan_dir);
        auto files = fut.get();
        CHECK(files.size() == 5);
    }

    // 10. 进度回调
    {
        file_scan::FileScanner s;
        int n = 0;
        s.scan(scan_dir, {}, [&](const file_scan::FileInfo&) { ++n; });
        CHECK(n == 5);
    }

    // 11. 多目录扫描
    {
        fs::path d1 = scan_dir / "multi1";
        fs::path d2 = scan_dir / "multi2";
        write_file(d1 / "x.mp4", "x");
        write_file(d1 / "y.txt", "x");
        write_file(d2 / "z.mp3", "x");
        file_scan::FileScanner s;
        auto files = s.scan(std::vector<fs::path>{d1, d2});
        CHECK(files.size() == 3);
    }

    // 12. 增量索引
    {
        fs::path inc = tmp / "incr";
        write_file(inc / "a.mp4", "a");
        write_file(inc / "b.mp3", "b");
        fs::path idx = tmp / "incr.jsonl";
        file_scan::FileScanner s;
        auto d1 = s.build_index_incremental(inc, idx);
        CHECK(d1.added == 2);
        CHECK(d1.unchanged == 0);

        auto d2 = s.build_index_incremental(inc, idx);
        CHECK(d2.added == 0);
        CHECK(d2.unchanged == 2);

        write_file(inc / "b.mp3", "b-changed-long");
        auto d3 = s.build_index_incremental(inc, idx);
        CHECK(d3.modified == 1);
        CHECK(d3.unchanged == 1);

        fs::remove(inc / "a.mp4");
        write_file(inc / "c.txt", "c");
        auto d4 = s.build_index_incremental(inc, idx);
        CHECK(d4.deleted == 1);
        CHECK(d4.added == 1);
        CHECK(d4.unchanged == 1);
    }

    // 13. 取消令牌
    {
        fs::path big = tmp / "big";
        for (int i = 0; i < 3000; ++i)
            write_file(big / ("f" + std::to_string(i) + ".mp4"), "x");
        file_scan::FileScanner s;
        std::atomic<bool> cancel(false);
        std::vector<file_scan::FileInfo> r;
        file_scan::ScanOptions opts;
        opts.num_threads = 1;
        std::thread t([&] { r = s.scan(big, opts, nullptr, &cancel); });
        cancel.store(true);
        t.join();
        CHECK(r.size() <= 3000);
    }

    // 14. 并行取消不死锁（回归：pop 后取消退出也必须归还 pending 计数）
    {
        fs::path big = tmp / "bigpar";
        for (int i = 0; i < 3000; ++i)
            write_file(big / ("f" + std::to_string(i) + ".mp4"), "x");
        file_scan::FileScanner s;
        std::atomic<bool> cancel(false);
        file_scan::ScanOptions opts;   // num_threads=0 -> 并行
        std::vector<file_scan::FileInfo> r;
        std::thread t([&] { r = s.scan(big, opts, nullptr, &cancel); });
        cancel.store(true);            // 立即取消：任何时序下都不得挂死 join
        t.join();
        CHECK(r.size() <= 3000);
    }

    // 15. export_json：标准 JSON 数组 + summary + 单条字段
    {
        file_scan::FileScanner s;
        fs::path js = tmp / "export.json";
        CHECK(s.export_json(scan_dir, js));
        std::string all = read_all(js);
        CHECK(all.compare(0, 10, "{\"files\":[") == 0);
        CHECK(all.size() >= 2 && all.back() == '\n' && all[all.size() - 2] == '}');
        CHECK(all.find("\"summary\":{\"total_files\":") != std::string::npos);
        CHECK(all.find("\"by_type\":") != std::string::npos);
        CHECK(all.find("\"directory\":\"") != std::string::npos);
        CHECK(all.find("\"name\":\"a.mp4\"") != std::string::npos);
        CHECK(all.find("\"type\":\"video\"") != std::string::npos);
        CHECK(all.find("\"type\":\"audio\"") != std::string::npos);
        CHECK(all.find("\"type\":\"image\"") != std::string::npos);
        CHECK(all.find("\"size\":1") != std::string::npos);
        CHECK(count_of(all, "\"name\":\"") == 8);       // scan_dir 8 个可见文件
        CHECK(all.find("\"total_files\":8") != std::string::npos);
    }

    // 16. write_json：内存结果过滤后导出
    {
        file_scan::FileScanner s;
        auto files = s.scan(scan_dir);
        auto vids = file_scan::filter_by_type(files, file_scan::FileType::Video);
        CHECK(vids.size() == 3);                        // a.mp4 / sub/e.mkv / multi1/x.mp4
        fs::path js = tmp / "videos.json";
        CHECK(file_scan::write_json(vids, js));
        std::string all = read_all(js);
        CHECK(count_of(all, "\"type\":\"video\"") == 3);
        CHECK(all.find("\"type\":\"audio\"") == std::string::npos);
        CHECK(all.find("\"type\":\"text\"") == std::string::npos);
        CHECK(all.find("\"total_files\":3") != std::string::npos);
        CHECK(all.find("\"total_size\":3") != std::string::npos);   // 每文件 1 字节
        // 关闭 summary / pretty
        file_scan::JsonExportOptions jo;
        jo.include_summary = false;
        jo.pretty = false;
        CHECK(file_scan::write_json(vids, js, jo));
        std::string all2 = read_all(js);
        CHECK(all2.find("summary") == std::string::npos);
        CHECK(all2.find('\n') == std::string::npos);
        CHECK(all2.compare(0, 10, "{\"files\":[") == 0);
    }

    // 17. JSONL 索引含 directory 字段且 load 兼容
    {
        file_scan::FileScanner s;
        fs::path idx = tmp / "index_v2.jsonl";
        CHECK(s.build_index(scan_dir, idx));
        std::string all = read_all(idx);
        CHECK(all.find("\"directory\":\"") != std::string::npos);
        auto loaded = s.load_index(idx);
        auto orig   = s.scan(scan_dir);
        CHECK(loaded.size() == orig.size());
        bool all_match = true;
        for (auto& f : loaded)
            if (f.name.empty() || f.extension.empty()) { all_match = false; break; }
        CHECK(all_match);
    }

    // 18. MPEG-TS 魔数收紧：'G'(0x47) 开头不再误判，188 字节周期才判视频
    {
        file_scan::TypeDetector d;
        fs::path p1 = magic_dir / "gtext.bin";
        write_file(p1, std::string("GXYZ"));            // 4 字节，0x47 开头无周期
        CHECK(d.detect_by_magic(p1) == file_scan::FileType::Unknown);
        std::string ts(189, '\x47');                     // head[0]==head[188]==0x47
        fs::path p2 = magic_dir / "ts.bin";
        write_file(p2, ts);
        CHECK(d.detect_by_magic(p2) == file_scan::FileType::Video);
    }

    // 19. 非 ASCII 路径：JSON 输出必须是 UTF-8，load 往返路径可用
    {
        const char* cn = (const char*)u8"\u4e2d\u6587";       // "中文"
        const char* vf = (const char*)u8"\u89c6\u9891.mp4";  // "视频.mp4"
        fs::path cdir = scan_dir / fs::u8path(cn);
        write_file(cdir / fs::u8path(vf), "x");
        file_scan::FileScanner s;
        auto files = s.scan(cdir);
        CHECK(files.size() == 1);
        CHECK(files[0].type == file_scan::FileType::Video);

        fs::path js = tmp / "utf8.json";
        CHECK(s.export_json(cdir, js));
        CHECK(read_all(js).find(vf) != std::string::npos);   // UTF-8 字节序列

        fs::path idx = tmp / "utf8.jsonl";
        CHECK(s.build_index(cdir, idx));
        CHECK(read_all(idx).find(vf) != std::string::npos);
        auto loaded = s.load_index(idx);
        CHECK(loaded.size() == 1);
        CHECK(loaded[0].type == file_scan::FileType::Video);
        CHECK(loaded[0].name == files[0].name);
        std::error_code sec;
        CHECK(fs::is_regular_file(loaded[0].path, sec));    // 往返后路径仍指向该文件

        fs::remove_all(cdir, sec);
    }

    fs::remove_all(tmp, ec);
    std::printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
