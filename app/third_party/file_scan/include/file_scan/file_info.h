#pragma once

#include <string>
#include <cstdint>
#include <filesystem>
#include <chrono>

namespace file_scan {

enum class FileType : int {
    Video   = 0,
    Audio   = 1,
    Image   = 2,
    Text    = 3,
    Unknown = 99
};

inline const char* to_string(FileType t) {
    switch (t) {
        case FileType::Video:   return "video";
        case FileType::Audio:   return "audio";
        case FileType::Image:   return "image";
        case FileType::Text:    return "text";
        case FileType::Unknown: return "unknown";
    }
    return "unknown";
}

inline FileType file_type_from_string(const std::string& s) {
    if (s == "video")   return FileType::Video;
    if (s == "audio")   return FileType::Audio;
    if (s == "image")   return FileType::Image;
    if (s == "text")    return FileType::Text;
    return FileType::Unknown;
}

struct FileInfo {
    std::filesystem::path path;
    std::string name;
    std::string extension;          // 小写，含点，如 ".mp4"
    FileType    type = FileType::Unknown;
    std::uintmax_t size = 0;        // 字节数
    std::int64_t   modified_time = 0; // 自 epoch 的秒数
    bool is_directory = false;
};

} // namespace file_scan
