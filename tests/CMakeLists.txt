add_executable(chunkvault_tests
  app_config_test.cpp
)
target_link_libraries(chunkvault_tests PRIVATE
  chunkvault_lib
  GTest::gtest_main
)

include(GoogleTest)
gtest_discover_tests(chunkvault_tests)
