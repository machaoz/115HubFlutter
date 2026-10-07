add_executable(scan_demo demo.cpp)
target_link_libraries(scan_demo PRIVATE file_scan::file_scan)
target_compile_features(scan_demo PRIVATE cxx_std_17)
