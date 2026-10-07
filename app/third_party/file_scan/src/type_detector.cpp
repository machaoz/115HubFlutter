#include "file_scan/type_detector.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <initializer_list>
#include <array>

namespace file_scan {

namespace {

std::string to_lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

std::string strip_leading_dot(std::string s) {
    if (!s.empty() && s.front() == '.') s.erase(0, 1);
    return s;
}

bool read_head(const std::filesystem::path& path, std::size_t n,
               std::vector<unsigned char>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    out.resize(n);
    f.read(reinterpret_cast<char*>(out.data()), static_cast<std::streamsize>(n));
    out.resize(static_cast<std::size_t>(f.gcount()));
    return true;
}

bool bytes_equal(const std::vector<unsigned char>& head, std::size_t offset,
                 const std::vector<unsigned char>& sig) {
    if (offset + sig.size() > head.size()) return false;
    for (std::size_t i = 0; i < sig.size(); ++i)
        if (head[offset + i] != sig[i]) return false;
    return true;
}

std::vector<unsigned char> str_to_bytes(const char* s) {
    return std::vector<unsigned char>(s, s + std::strlen(s));
}

} // namespace

TypeDetector::TypeDetector() {
    register_defaults();
}

TypeDetector::~TypeDetector() = default;

void TypeDetector::register_extension(std::string ext, FileType type) {
    ext = to_lower(strip_leading_dot(std::move(ext)));
    ext_map_[std::move(ext)] = type;
}

void TypeDetector::register_magic(std::size_t offset,
                                  std::vector<unsigned char> bytes,
                                  FileType type) {
    magics_.push_back({offset, std::move(bytes), type});
}

FileType TypeDetector::detect_by_extension(std::string_view ext) const {
    std::string key = to_lower(strip_leading_dot(std::string(ext)));
    auto it = ext_map_.find(key);
    return it == ext_map_.end() ? FileType::Unknown : it->second;
}

FileType TypeDetector::detect_by_magic(const std::filesystem::path& path) const {
    if (!magic_enabled_) return FileType::Unknown;

    // 读 256 字节：覆盖 TS 188 字节周期的同步验证（读一次成本与 64 字节相同）
    std::vector<unsigned char> head;
    if (!read_head(path, 256, head) || head.empty()) return FileType::Unknown;

    // RIFF 容器优先识别：RIFF + FourCC
    if (head.size() >= 12 && bytes_equal(head, 0, str_to_bytes("RIFF"))) {
        if (bytes_equal(head, 8, str_to_bytes("WAVE"))) return FileType::Audio;
        if (bytes_equal(head, 8, str_to_bytes("AVI "))) return FileType::Video;
        if (bytes_equal(head, 8, str_to_bytes("WEBP"))) return FileType::Image;
    }
    // MPEG-TS：0x47 同步字节且在 188 字节周期处再次出现。
    // 仅凭首字节 0x47（'G'）判定会误伤大量普通二进制/文本文件。
    if (head.size() >= 189 && head[0] == 0x47 && head[188] == 0x47)
        return FileType::Video;

    for (const auto& sig : magics_) {
        if (bytes_equal(head, sig.offset, sig.bytes)) return sig.type;
    }
    return FileType::Unknown;
}

FileType TypeDetector::detect(const std::filesystem::path& path) const {
    std::string ext = normalized_extension(path);
    if (!ext.empty()) {
        FileType t = detect_by_extension(ext);
        if (t != FileType::Unknown) return t;
    }
    return detect_by_magic(path);
}

void TypeDetector::set_magic_enabled(bool enabled) {
    magic_enabled_ = enabled;
}
bool TypeDetector::magic_enabled() const {
    return magic_enabled_;
}

std::string TypeDetector::normalized_extension(const std::filesystem::path& p) {
    // 经 u8string 走 UTF-8：MSVC 的 path::string() 按当前代码页（GBK）窄化，
    // 遇 GBK 表示不了的字符会抛 system_error（详见 file_scan.cpp path_u8 注释）
#if defined(__cpp_lib_char8_t)
    const auto u8 = p.extension().u8string();
    std::string ext(u8.begin(), u8.end());
#else
    std::string ext = p.extension().u8string();
#endif
    return to_lower(std::move(ext));
}

void TypeDetector::register_defaults() {
    // 视频
    static const char* video_ext[] = {
        "mp4","m4v","mkv","avi","mov","flv","wmv","mpeg","mpg","webm",
        "3gp","3g2","ts","m2ts","vob","ogv","rm","rmvb","asf","f4v",
        "mts","divx","xvid"
    };
    // 音频
    static const char* audio_ext[] = {
        "mp3","wav","flac","aac","ogg","opus","m4a","wma","aiff","aif",
        "alac","ape","amr","dsf","dff","mid","midi","mp2","mka","ac3"
    };
    // 图片
    static const char* image_ext[] = {
        "jpg","jpeg","png","gif","bmp","tiff","tif","webp","svg","heic",
        "heif","raw","cr2","nef","arw","psd","ico","jfif","avif","hdr"
    };
    // 文本
    static const char* text_ext[] = {
        "txt","log","csv","json","xml","ini","cfg","conf","md","markdown",
        "html","htm","srt","ass","vtt","nfo","yaml","yml","toml","tex",
        "rtf","tsv","properties","plist","lang"
    };

    for (auto e : video_ext) ext_map_[e] = FileType::Video;
    for (auto e : audio_ext) ext_map_[e] = FileType::Audio;
    for (auto e : image_ext) ext_map_[e] = FileType::Image;
    for (auto e : text_ext)  ext_map_[e] = FileType::Text;

    // 魔数签名
    auto add = [&](std::size_t off, const char* s, FileType t) {
        magics_.push_back({off, str_to_bytes(s), t});
    };
    auto addHex = [&](std::size_t off, std::initializer_list<unsigned char> hs, FileType t) {
        magics_.push_back({off, std::vector<unsigned char>(hs), t});
    };

    // 视频
    add(4, "ftyp", FileType::Video);          // MP4/MOV/M4V
    addHex(0, {0x1A,0x45,0xDF,0xA3}, FileType::Video); // MKV/WebM (EBML)
    add(0, "FLV", FileType::Video);
    addHex(0, {0x30,0x26,0xB2,0x75}, FileType::Video); // WMV/ASF
    // 音频
    add(0, "ID3", FileType::Audio);           // MP3 (ID3 标签)
    addHex(0, {0xFF,0xFB}, FileType::Audio);  // MP3 (MPEG-1 L3)
    addHex(0, {0xFF,0xF3}, FileType::Audio);  // MP3 (MPEG-2.5 L3)
    addHex(0, {0xFF,0xFA}, FileType::Audio);  // MP3 (MPEG-2 L3)
    add(0, "fLaC", FileType::Audio);
    add(0, "OggS", FileType::Audio);
    // 图片
    addHex(0, {0xFF,0xD8,0xFF}, FileType::Image);       // JPEG
    addHex(0, {0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A}, FileType::Image); // PNG
    add(0, "GIF87a", FileType::Image);
    add(0, "GIF89a", FileType::Image);
    add(0, "BM", FileType::Image);                       // BMP
    addHex(0, {0x49,0x49,0x2A,0x00}, FileType::Image);   // TIFF (LE)
    addHex(0, {0x4D,0x4D,0x00,0x2A}, FileType::Image);   // TIFF (BE)
    // 文本
    addHex(0, {0xEF,0xBB,0xBF}, FileType::Text);        // UTF-8 BOM
}

} // namespace file_scan
