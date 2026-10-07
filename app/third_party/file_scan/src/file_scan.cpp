#include "file_scan/file_scan.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <mutex>
#include <queue>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <unordered_map>
#include <unordered_set>

namespace file_scan {

namespace fsn = std::filesystem;  // 别名，避免与参数名冲突

namespace {

namespace fs = std::filesystem;   // 文件内简写

std::string to_lower_impl(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

std::int64_t to_epoch_seconds(const fs::file_time_type& t) {
    return std::chrono::duration_cast<std::chrono::seconds>(t.time_since_epoch()).count();
}

// 规范化扩展名：小写，确保以点开头（如 "MP4" -> ".mp4"）
std::string normalize_extension(std::string e) {
    e = to_lower_impl(std::move(e));
    if (!e.empty() && e.front() != '.') e.insert(e.begin(), '.');
    return e;
}

// C++17 的 u8string()/generic_u8string() 返回 std::string，
// C++20 起返回 std::u8string；以下重载统一得到 UTF-8 的 std::string。
std::string to_utf8(const std::string& s) { return s; }
#if defined(__cpp_lib_char8_t)
std::string to_utf8(const std::u8string& s) {
    return std::string(s.begin(), s.end());
}
#endif

// UTF-8 std::string -> path（C++17: u8path；C++20: u8string 构造）
fs::path from_utf8(const std::string& s) {
#if defined(__cpp_lib_char8_t)
    return fs::path(std::u8string(s.begin(), s.end()));
#else
    return fs::u8path(s);
#endif
}

// MSVC 下 path::string()/generic_string() 按当前代码页（GBK）窄化，遇到
// GBK 表示不了的字符（U+2011 连字符、emoji 等合法文件名字符）会直接抛
// system_error("No mapping for the Unicode character exists in the target
// multi-byte code page.")—— 扫描线程未捕获即 std::terminate（进程 abort）。
// 因此所有取名字符串一律经 u8string 走 UTF-8 通道，与 JSON 输出同约定。
std::string path_u8(const fs::path& p)         { return to_utf8(p.u8string()); }
std::string path_generic_u8(const fs::path& p) { return to_utf8(p.generic_u8string()); }

std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b";  break;
            case '\f': out += "\\f";  break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x",
                                  static_cast<unsigned int>(c));
                    out += buf;
                } else {
                    out += c;   // 含 UTF-8 多字节序列，原样透传
                }
        }
    }
    return out;
}

std::string json_unescape(std::string s) {
    std::string out;
    out.reserve(s.size());
    for (std::size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '\\' && i + 1 < s.size()) {
            char n = s[i + 1];
            switch (n) {
                case '"':  out += '"';  break;
                case '\\': out += '\\'; break;
                case '/':  out += '/';  break;
                case 'b':  out += '\b'; break;
                case 'f':  out += '\f'; break;
                case 'n':  out += '\n'; break;
                case 'r':  out += '\r'; break;
                case 't':  out += '\t'; break;
                case 'u': {
                    if (i + 5 < s.size()) {
                        unsigned int cp = 0;
                        std::sscanf(s.c_str() + i + 2, "%4x", &cp);
                        if (cp < 0x80) out += static_cast<char>(cp);
                        else if (cp < 0x800) {
                            out += static_cast<char>(0xC0 | (cp >> 6));
                            out += static_cast<char>(0x80 | (cp & 0x3F));
                        } else {
                            out += static_cast<char>(0xE0 | (cp >> 12));
                            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
                            out += static_cast<char>(0x80 | (cp & 0x3F));
                        }
                        i += 4;
                    }
                    break;
                }
                default: out += n;
            }
            ++i;
        } else {
            out += s[i];
        }
    }
    return out;
}

bool extract_string(const std::string& line, const std::string& key, std::string& out) {
    std::string pat = "\"" + key + "\":\"";
    std::size_t k = line.find(pat);
    if (k == std::string::npos) return false;
    k += pat.size();
    std::size_t start = k;
    while (k < line.size()) {
        if (line[k] == '\\') { k += 2; continue; }   // 转义序列整体跳过
        if (line[k] == '"') break;                    // 未转义的闭引号
        ++k;
    }
    out = json_unescape(line.substr(start, k - start));
    return true;
}

bool extract_int(const std::string& line, const std::string& key, std::int64_t& out) {
    std::string pat = "\"" + key + "\":";
    std::size_t k = line.find(pat);
    if (k == std::string::npos) return false;
    k += pat.size();
    try {
        out = std::stoll(line.substr(k));
    } catch (...) {
        return false;
    }
    return true;
}

bool extract_bool(const std::string& line, const std::string& key, bool& out) {
    std::string pat = "\"" + key + "\":";
    std::size_t k = line.find(pat);
    if (k == std::string::npos) return false;
    k += pat.size();
    if (line.compare(k, 4, "true") == 0)  { out = true;  return true; }
    if (line.compare(k, 5, "false") == 0) { out = false; return true; }
    return false;
}

// 单条记录的字段序列（不含大括号），字符串一律 UTF-8：
// "directory":"...","name":"...","extension":"...","type":"...","size":N,"modified_time":N
std::string json_fields(const FileInfo& f) {
    std::string s;
    s.reserve(256 + path_u8(f.path).size() * 2);
    s += "\"directory\":\"";     s += json_escape(to_utf8(f.path.parent_path().generic_u8string()));
    s += "\",\"name\":\"";      s += json_escape(to_utf8(f.path.filename().u8string()));
    s += "\",\"extension\":\""; s += json_escape(f.extension);
    s += "\",\"type\":\"";      s += to_string(f.type);
    s += "\",\"size\":";        s += std::to_string(f.size);
    s += ",\"modified_time\":"; s += std::to_string(f.modified_time);
    return s;
}

// JSONL 索引行：path + 公共字段 + 可选 status
std::string json_line(const FileInfo& f, const char* status = nullptr) {
    std::string s;
    s.reserve(320 + path_u8(f.path).size() * 2);
    s += "{\"path\":\"";        s += json_escape(to_utf8(f.path.generic_u8string()));
    s += "\",";
    s += json_fields(f);
    if (status) { s += ",\"status\":\""; s += status; s += "\""; }
    s += "}\n";
    return s;
}

struct Shard { fs::path dir; std::size_t depth; };

struct WorkQueue {
    std::mutex m;
    std::condition_variable cv;
    std::queue<Shard> q;
    std::atomic<std::size_t> pending{0};

    void push(Shard s) {
        {
            std::lock_guard<std::mutex> lk(m);
            q.push(std::move(s));
        }
        pending.fetch_add(1, std::memory_order_acq_rel);
        cv.notify_one();
    }
    bool pop(Shard& out) {
        std::unique_lock<std::mutex> lk(m);
        cv.wait(lk, [&] {
            return !q.empty() || pending.load(std::memory_order_acquire) == 0;
        });
        if (q.empty()) return false;
        out = std::move(q.front());
        q.pop();
        return true;
    }
    void finished() {
        if (pending.fetch_sub(1, std::memory_order_acq_rel) == 1) {
            cv.notify_all();
        }
    }
};

// 标准数组 JSON 的流式写出器：{"files":[ ... ],"summary":{...}}。
// 先流式写条目、收尾补 summary，内存峰值与文件总数无关。
class JsonExportWriter {
public:
    explicit JsonExportWriter(const fs::path& target, bool pretty = true)
        : target_(target), pretty_(pretty) {
        std::error_code ec;
        fs::path tmp_dir = fs::temp_directory_path(ec);
        if (ec || tmp_dir.empty()) tmp_dir = target.parent_path();
        if (tmp_dir.empty()) tmp_dir = ".";
        static std::atomic<int> g_id{0};
        tmp_ = tmp_dir / ("file_scan_json_" + std::to_string(g_id.fetch_add(1)) + ".tmp");
        out_.open(tmp_, std::ios::binary | std::ios::trunc);
        use_tmp_ = static_cast<bool>(out_);
        if (!use_tmp_) { tmp_ = target; out_.open(tmp_, std::ios::binary | std::ios::trunc); }
        if (out_) out_ << "{\"files\":[";
        skip_ = path_generic_u8(tmp_);
    }

    bool ok() const { return static_cast<bool>(out_); }

    // 临时文件路径（扫描回调中跳过自身，避免把导出文件写进结果）
    const std::string& skip_path() const { return skip_; }

    void add(const FileInfo& f) {
        if (!out_) return;
        if (count_ == 0) out_ << (pretty_ ? "\n  " : "");
        else            out_ << (pretty_ ? ",\n  " : ",");
        out_ << '{' << json_fields(f) << '}';
        total_size_ += f.size;
        ++counts_[type_index(f.type)];
        ++count_;
    }

    bool finish(bool include_summary) {
        if (!out_) return false;
        if (count_ != 0 && pretty_) out_ << '\n';
        out_ << "]";
        if (include_summary) {
            static const char* names[5] = {"video", "audio", "image", "text", "unknown"};
            out_ << ",\"summary\":{\"total_files\":" << count_
                 << ",\"total_size\":" << total_size_ << ",\"by_type\":{";
            bool first = true;
            for (int i = 0; i < 5; ++i) {
                if (counts_[i] == 0) continue;
                out_ << (first ? "" : ",") << '"' << names[i] << "\":" << counts_[i];
                first = false;
            }
            out_ << "}}";
        }
        out_ << "}" << (pretty_ ? "\n" : "");
        out_.flush();
        out_.close();
        if (!out_) {
            std::error_code ec;
            if (use_tmp_) fs::remove(tmp_, ec);
            return false;
        }
        std::error_code ec;
        if (use_tmp_) {
            fs::rename(tmp_, target_, ec);
            if (ec) {
                fs::copy_file(tmp_, target_, fs::copy_options::overwrite_existing, ec);
                fs::remove(tmp_, ec);
                return !ec;
            }
        }
        return true;
    }

private:
    static std::size_t type_index(FileType t) {
        switch (t) {
            case FileType::Video: return 0;
            case FileType::Audio: return 1;
            case FileType::Image: return 2;
            case FileType::Text:  return 3;
            default:              return 4;
        }
    }

    fs::path target_, tmp_;
    std::ofstream out_;
    std::string skip_;
    bool pretty_   = true;
    bool use_tmp_  = false;
    std::size_t counts_[5] = {0, 0, 0, 0, 0};
    std::uintmax_t total_size_ = 0;
    std::size_t count_ = 0;
};

} // namespace

FileScanner::FileScanner() : detector_() {}
FileScanner::FileScanner(TypeDetector detector) : detector_(std::move(detector)) {}
FileScanner::~FileScanner() = default;

std::vector<FileInfo>
FileScanner::scan(const fsn::path& dir, const ScanOptions& opts,
                  ProgressCallback cb, const std::atomic<bool>* cancel) const {
    return scan_impl({dir}, opts, cb, cancel, true);
}

std::vector<FileInfo>
FileScanner::scan(const std::vector<fsn::path>& dirs, const ScanOptions& opts,
                  ProgressCallback cb, const std::atomic<bool>* cancel) const {
    return scan_impl(dirs, opts, cb, cancel, true);
}

std::future<std::vector<FileInfo>>
FileScanner::scan_async(const fsn::path& dir, const ScanOptions& opts,
                         ProgressCallback cb) const {
    return std::async(std::launch::async,
                      [this, dir, opts, cb]() { return this->scan(dir, opts, cb); });
}

std::vector<FileInfo>
FileScanner::scan_impl(const std::vector<fsn::path>& dirs, const ScanOptions& opts,
                        ProgressCallback cb, const std::atomic<bool>* cancel,
                        bool collect) const {
    std::vector<fsn::path> valid;
    for (const auto& d : dirs) {
        std::error_code ec;
        if (fsn::is_directory(d, ec)) valid.push_back(d);
    }
    if (valid.empty()) return {};

    std::size_t hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 1;
    std::size_t nt = opts.num_threads == 0 ? hw : opts.num_threads;

    auto cancelled = [&]() { return cancel && cancel->load(std::memory_order_relaxed); };

    // ---- 过滤条件预处理（O(1) 哈希查找，避免逐文件重复 to_lower/线性扫描）----
    std::unordered_set<std::string> inc_ext, exc_ext;
    for (const auto& e : opts.include_extensions) inc_ext.insert(normalize_extension(e));
    for (const auto& e : opts.exclude_extensions) exc_ext.insert(normalize_extension(e));
    std::unordered_set<int> inc_types;
    for (FileType t : opts.include_types) inc_types.insert(static_cast<int>(t));
    const bool filter_type = !inc_types.empty();

    // follow_symlinks=true 时的符号链接环检测（仅显式开启才付出 canonical 开销）
    const bool guard_cycles = opts.follow_symlinks;
    std::unordered_set<std::string> visited;
    std::mutex visited_mtx;
    auto mark_visited = [&](const fsn::path& dir) {
        std::error_code ec;
        fsn::path c = fsn::weakly_canonical(dir, ec);
        if (ec) return true;   // 解析失败则放行
        std::lock_guard<std::mutex> lk(visited_mtx);
        return visited.insert(path_generic_u8(c)).second;   // false=已访问(环)
    };

    // ---- 共享遍历逻辑（串行/并行两个分支复用，避免两份拷贝漂移）----

    // 条目是否按目录处理。不跟随符号链接时，symlink 一律视为非目录，
    // 使 MSVC / libstdc++ 行为一致，且默认路径下天然免疫符号链接环。
    auto entry_is_dir = [&](const fsn::directory_entry& entry) -> bool {
        std::error_code ec;
        if (!opts.follow_symlinks && entry.is_symlink(ec)) return false;
        return entry.is_directory(ec);
    };

    // 目录条目是否递归深入
    auto should_descend = [&](const fsn::directory_entry& entry, std::size_t depth) -> bool {
        if (!opts.recursive) return false;
        if (opts.max_depth != 0 && depth + 1 >= opts.max_depth) return false;
        if (!opts.include_hidden) {
            std::string dname = path_u8(entry.path().filename());
            if (!dname.empty() && dname[0] == '.') return false;
            for (const auto& skip : opts.exclude_dir_names) {
                if (dname == skip) return false;
            }
        }
        return true;
    };

    // 文件条目 -> FileInfo；返回 false 表示应跳过。
    // 廉价过滤前置：hidden / 扩展名 / 扩展名命中类型，全部通过后才做魔数检测，
    // 避免 include_types 过滤场景下对每个未知扩展文件白读一次文件头（IO）。
    auto accept_entry = [&](const fsn::directory_entry& entry, FileInfo& info) -> bool {
        info.path = entry.path();
        info.name = path_u8(info.path.filename());
        info.is_directory = false;
        info.extension = TypeDetector::normalized_extension(info.path);

        if (!opts.include_hidden && !info.name.empty() && info.name[0] == '.') return false;
        if (!inc_ext.empty() && !inc_ext.count(info.extension)) return false;
        if (exc_ext.count(info.extension)) return false;

        info.type = detector_.detect_by_extension(info.extension);
        if (filter_type && info.type != FileType::Unknown &&
            !inc_types.count(static_cast<int>(info.type))) return false;
        if (info.type == FileType::Unknown)
            info.type = detector_.detect_by_magic(info.path);   // 此处才可能产生文件 IO
        if (filter_type && !inc_types.count(static_cast<int>(info.type))) return false;

        std::error_code ec;
        info.size = entry.file_size(ec);
        if (ec) info.size = 0;
        auto lwt = entry.last_write_time(ec);
        info.modified_time = ec ? 0 : to_epoch_seconds(lwt);
        return true;
    };

    fsn::directory_options dopts = fsn::directory_options::skip_permission_denied;
    if (opts.follow_symlinks) dopts |= fsn::directory_options::follow_directory_symlink;

    if (nt <= 1) {
        // ---- 串行 ----
        std::vector<FileInfo> result;
        if (collect) result.reserve(2048);
        std::function<void(const fsn::path&, std::size_t)> walk;
        walk = [&](const fsn::path& cur, std::size_t depth) {
            if (cancelled()) return;
            if (guard_cycles && !mark_visited(cur)) return;   // 符号链接环
            std::error_code ec;
            fsn::directory_iterator iter(cur, dopts, ec), end;
            while (!ec && iter != end) {
                if (cancelled()) return;
                const auto& entry = *iter;
                if (entry_is_dir(entry)) {
                    if (should_descend(entry, depth))
                        walk(entry.path(), depth + 1);
                } else {
                    FileInfo info;
                    if (accept_entry(entry, info)) {
                        if (cb) cb(info);
                        if (collect) result.push_back(std::move(info));
                    }
                }
                iter.increment(ec);
            }
        };
        for (const auto& d : valid) walk(d, 0);
        return result;
    }

    // ---- 并行（工作队列 + 条件变量动态调度子目录）----
    WorkQueue wq;
    for (const auto& d : valid) wq.push({d, 0});
    std::mutex cb_mtx;
    std::vector<std::vector<FileInfo>> locals(nt);
    std::vector<std::thread> threads;
    threads.reserve(nt);

    auto worker = [&](std::size_t tid) {
        auto& local = locals[tid];
        if (collect) local.reserve(2048);
        Shard sh;
        while (wq.pop(sh)) {
            // pop 成功即“占用”了该 shard，取消退出也必须归还计数，
            // 否则 pending 永不归零，其余 worker 将永远阻塞在 cv.wait（死锁）。
            if (cancelled()) { wq.finished(); break; }
            if (guard_cycles && !mark_visited(sh.dir)) { wq.finished(); continue; }
            std::error_code ec;
            fsn::directory_iterator iter(sh.dir, dopts, ec), end;
            while (!ec && iter != end) {
                if (cancelled()) break;
                const auto& entry = *iter;
                if (entry_is_dir(entry)) {
                    if (should_descend(entry, sh.depth))
                        wq.push({entry.path(), sh.depth + 1});
                } else {
                    FileInfo info;
                    if (accept_entry(entry, info)) {
                        if (cb) {
                            std::lock_guard<std::mutex> lk(cb_mtx);
                            cb(info);
                        }
                        if (collect) local.push_back(std::move(info));
                    }
                }
                iter.increment(ec);
            }
            wq.finished();
        }
    };

    for (std::size_t i = 0; i < nt; ++i) threads.emplace_back(worker, i);
    for (auto& t : threads) t.join();

    std::vector<FileInfo> result;
    if (collect) {
        std::size_t total = 0;
        for (auto& l : locals) total += l.size();
        result.reserve(total);
        for (auto& l : locals)
            result.insert(result.end(),
                          std::make_move_iterator(l.begin()),
                          std::make_move_iterator(l.end()));
    }
    return result;
}

bool FileScanner::build_index(const fsn::path& dir, const fsn::path& index_file,
                               const ScanOptions& opts,
                               const std::atomic<bool>* cancel) const {
    static std::atomic<int> g_id{0};
    std::error_code ec;
    fsn::path tmp_dir = fsn::temp_directory_path(ec);
    if (ec || tmp_dir.empty()) tmp_dir = index_file.parent_path();
    fsn::path tmp = tmp_dir / ("file_scan_" + std::to_string(g_id.fetch_add(1)) + ".tmp");

    std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
    bool use_tmp = static_cast<bool>(out);
    if (!use_tmp) { tmp = index_file; out.open(tmp, std::ios::binary | std::ios::trunc); }
    if (!out) return false;

    out << "# file_scan index v2 (JSON Lines)\n";
    out << "# dir: " << json_escape(to_utf8(dir.generic_u8string())) << "\n";

    std::string skip = path_generic_u8(tmp);
    auto cb = [&](const FileInfo& f) {
        if (path_generic_u8(f.path) == skip) return;
        out << json_line(f);
    };
    scan_impl({dir}, opts, cb, cancel, false);
    out.flush();
    out.close();

    if (use_tmp) {
        fsn::rename(tmp, index_file, ec);
        if (ec) {
            fsn::copy_file(tmp, index_file, fsn::copy_options::overwrite_existing, ec);
            fsn::remove(tmp, ec);
        }
    }
    return true;
}

IndexDiff FileScanner::build_index_incremental(const fsn::path& dir,
                                                 const fsn::path& index_file,
                                                 const ScanOptions& opts,
                                                 const std::atomic<bool>* cancel) const {
    IndexDiff diff;
    auto old = load_index(index_file);
    std::unordered_map<std::string, FileInfo> old_map;
    for (auto& f : old) old_map[path_generic_u8(f.path)] = std::move(f);

    static std::atomic<int> g_id{0};
    std::error_code ec;
    fsn::path tmp_dir = fsn::temp_directory_path(ec);
    if (ec || tmp_dir.empty()) tmp_dir = index_file.parent_path();
    fsn::path tmp = tmp_dir / ("file_scan_inc_" + std::to_string(g_id.fetch_add(1)) + ".tmp");

    std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
    bool use_tmp = static_cast<bool>(out);
    if (!use_tmp) { tmp = index_file; out.open(tmp, std::ios::binary | std::ios::trunc); }
    if (!out) return diff;

    out << "# file_scan index v2 (JSON Lines)\n";
    out << "# dir: " << json_escape(to_utf8(dir.generic_u8string())) << "\n";

    std::string skip_tmp = path_generic_u8(tmp);
    std::string skip_idx = path_generic_u8(index_file);
    std::unordered_set<std::string> seen;
    std::size_t a_added = 0, a_modified = 0, a_unchanged = 0, a_deleted = 0;

    auto cb = [&](const FileInfo& f) {
        std::string key = path_generic_u8(f.path);
        if (key == skip_tmp || key == skip_idx) return;
        seen.insert(key);
        auto it = old_map.find(key);
        if (it == old_map.end()) {
            out << json_line(f, "new");       ++a_added;
        } else if (it->second.modified_time != f.modified_time ||
                   it->second.size != f.size) {
            out << json_line(f, "modified");  ++a_modified;
        } else {
            out << json_line(f, "unchanged"); ++a_unchanged;
        }
    };
    scan_impl({dir}, opts, cb, cancel, false);

    for (auto& kv : old_map) {
        if (seen.find(kv.first) == seen.end()) {
            out << json_line(kv.second, "deleted");
            ++a_deleted;
        }
    }
    out.flush();
    out.close();

    diff.added     = a_added;
    diff.modified  = a_modified;
    diff.unchanged = a_unchanged;
    diff.deleted   = a_deleted;

    if (use_tmp) {
        fsn::rename(tmp, index_file, ec);
        if (ec) {
            fsn::copy_file(tmp, index_file, fsn::copy_options::overwrite_existing, ec);
            fsn::remove(tmp, ec);
        }
    }
    return diff;
}

std::vector<FileInfo>
FileScanner::load_index(const fsn::path& index_file) const {
    std::vector<FileInfo> result;
    std::ifstream in(index_file, std::ios::binary);
    if (!in) return result;

    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line.front() != '{') continue;   // 跳过 # 注释与空行

        FileInfo f;
        std::string s, s2;
        if (extract_string(line, "path", s)) {
            f.path = from_utf8(s);
        } else if (extract_string(line, "directory", s) &&
                   extract_string(line, "name", s2)) {
            // 兼容仅含 directory + name 的条目
            f.path = from_utf8(s) / from_utf8(s2);
        }
        if (!f.path.empty()) {
            // path 为权威字段，name/extension 与扫描时同源推导
            f.name      = path_u8(f.path.filename());
            f.extension = TypeDetector::normalized_extension(f.path);
        } else {
            if (extract_string(line, "name", s))      f.name = s;
            if (extract_string(line, "extension", s)) f.extension = s;
        }
        if (extract_string(line, "type", s))        f.type = file_type_from_string(s);
        std::int64_t iv = 0;
        if (extract_int(line, "size", iv))          f.size = static_cast<std::uintmax_t>(iv);
        if (extract_int(line, "modified_time", iv)) f.modified_time = iv;
        bool b = false;
        if (extract_bool(line, "is_directory", b))  f.is_directory = b;
        result.push_back(std::move(f));
    }
    return result;
}

bool FileScanner::export_json(const fsn::path& dir, const fsn::path& json_file,
                               const ScanOptions& opts,
                               const std::atomic<bool>* cancel) const {
    // 流式：扫描回调直接写盘，内存峰值与文件总数无关
    JsonExportWriter w(json_file);
    if (!w.ok()) return false;
    const std::string skip = w.skip_path();
    auto cb = [&](const FileInfo& f) {
        if (path_generic_u8(f.path) == skip) return;   // 不写自身
        w.add(f);
    };
    scan_impl({dir}, opts, cb, cancel, false);
    return w.finish(true);
}

const TypeDetector& FileScanner::detector() const { return detector_; }
TypeDetector&       FileScanner::detector()       { return detector_; }

bool write_json(const std::vector<FileInfo>& files, const fsn::path& json_file,
                const JsonExportOptions& jopts) {
    JsonExportWriter w(json_file, jopts.pretty);
    if (!w.ok()) return false;
    for (const auto& f : files) w.add(f);
    return w.finish(jopts.include_summary);
}

std::vector<FileInfo> filter_by_type(const std::vector<FileInfo>& files, FileType type) {
    std::vector<FileInfo> out;
    std::copy_if(files.begin(), files.end(), std::back_inserter(out),
                 [type](const FileInfo& f) { return f.type == type; });
    return out;
}

std::vector<FileInfo> filter_by_extension(const std::vector<FileInfo>& files,
                                           const std::string& ext) {
    std::string norm = normalize_extension(ext);
    std::vector<FileInfo> out;
    std::copy_if(files.begin(), files.end(), std::back_inserter(out),
                 [&](const FileInfo& f) { return to_lower_impl(f.extension) == norm; });
    return out;
}

} // namespace file_scan
