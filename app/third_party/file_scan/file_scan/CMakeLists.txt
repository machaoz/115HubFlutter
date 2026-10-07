cmake_minimum_required(VERSION 3.14)

project(FileScan
    VERSION 1.1.0
    DESCRIPTION "Local file scanning & indexing library for media players"
    LANGUAGES CXX
)

# ---- 元数据（许可证）----
set(FILE_SCAN_LICENSE      "MIT")
set(FILE_SCAN_LICENSE_FILE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")

# ---- 选项 ----
option(FILE_SCAN_BUILD_TESTS    "Build FileScan unit tests"    ON)
option(FILE_SCAN_BUILD_EXAMPLES "Build FileScan examples"      ON)
option(FILE_SCAN_BUILD_SHARED   "Build shared instead of static library" OFF)
option(FILE_SCAN_INSTALL        "Generate install targets"     ON)

# ---- 语言标准 ----
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

# ---- 库目标 ----
if(FILE_SCAN_BUILD_SHARED)
    set(FILE_SCAN_LIB_TYPE SHARED)
else()
    set(FILE_SCAN_LIB_TYPE STATIC)
endif()

add_library(file_scan ${FILE_SCAN_LIB_TYPE}
    src/file_scan.cpp
    src/type_detector.cpp
)
add_library(file_scan::file_scan ALIAS file_scan)

target_include_directories(file_scan
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)

target_compile_features(file_scan PUBLIC cxx_std_17)

set_target_properties(file_scan PROPERTIES
    OUTPUT_NAME file_scan
    VERSION ${PROJECT_VERSION}
    SOVERSION ${PROJECT_VERSION_MAJOR}
    POSITION_INDEPENDENT_CODE ON
)

# ---- 子项目 ----
if(FILE_SCAN_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

if(FILE_SCAN_BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()

# ---- 安装与包配置 ----
if(FILE_SCAN_INSTALL)
    install(TARGETS file_scan
        EXPORT FileScanTargets
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
    )

    install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/include/
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
    )

    # 随包分发许可证文本
    if(EXISTS ${FILE_SCAN_LICENSE_FILE})
        install(FILES ${FILE_SCAN_LICENSE_FILE}
            DESTINATION ${CMAKE_INSTALL_DATAROOTDIR}/licenses/FileScan
        )
    endif()

    install(EXPORT FileScanTargets
        FILE FileScanTargets.cmake
        NAMESPACE file_scan::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/FileScan
    )

    configure_package_config_file(
        ${CMAKE_CURRENT_SOURCE_DIR}/cmake/FileScanConfig.cmake.in
        ${CMAKE_CURRENT_BINARY_DIR}/FileScanConfig.cmake
        INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/FileScan
    )

    write_basic_package_version_file(
        ${CMAKE_CURRENT_BINARY_DIR}/FileScanConfigVersion.cmake
        VERSION ${PROJECT_VERSION}
        COMPATIBILITY SameMajorVersion
    )

    install(FILES
        ${CMAKE_CURRENT_BINARY_DIR}/FileScanConfig.cmake
        ${CMAKE_CURRENT_BINARY_DIR}/FileScanConfigVersion.cmake
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/FileScan
    )
endif()
