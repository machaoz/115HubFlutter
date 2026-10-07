add_executable(test_scanner test_scanner.cpp)
target_link_libraries(test_scanner PRIVATE file_scan::file_scan)
target_compile_features(test_scanner PRIVATE cxx_std_17)

add_test(NAME test_scanner COMMAND test_scanner)
