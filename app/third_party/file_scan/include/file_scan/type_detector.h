#pragma once

#include "file_scan/file_info.h"
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>
#include <cstddef>
#include <filesystem>

namespace file_scan {

class TypeDetector {
public:
    TypeDetector();
    ~TypeDetector();

    TypeDetector(const TypeDetector&)            = default;
    TypeDetector& operator=(const TypeDetector&) = default;
    TypeDetector(TypeDetector&&) noexcept         = default;
    TypeDetector& operator=(TypeDetector&&) noexcept = default;

    // 自定义扩展名 -> 类型（ext 不含点也可，内部统一小写）
    void register_extension(std::string ext, FileType type);
    // 自定义魔数签名：(offset, bytes) -> 类型
    void register_magic(std::size_t offset,
                        std::vector<unsigned char> bytes,
                        FileType type);

    FileType detect_by_extension(std::string_view ext) const;
    FileType detect_by_magic(const std::filesystem::path& path) const;
    // 综合：先扩展名，命中非 Unknown 则返回；否则魔数
    FileType detect(const std::filesystem::path& path) const;

    void   set_magic_enabled(bool enabled);
    bool   magic_enabled() const;

    // 便捷：从路径取小写扩展名（含点）
    static std::string normalized_extension(const std::filesystem::path& p);

private:
    void register_defaults();

    struct MagicSig {
        std::size_t offset;
        std::vector<unsigned char> bytes;
        FileType type;
    };

    std::unordered_map<std::string, FileType> ext_map_;
    std::vector<MagicSig> magics_;
    bool magic_enabled_ = true;
};

} // namespace file_scan
