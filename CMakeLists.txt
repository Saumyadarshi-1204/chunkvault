cmake_minimum_required(VERSION 3.21)
project(chunkvault VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

enable_testing()

find_package(Drogon CONFIG REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(jwt-cpp CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)
find_package(nlohmann_json CONFIG REQUIRED)
find_package(GTest CONFIG REQUIRED)

add_library(chunkvault_lib STATIC
  src/api/health_controller.cpp
  src/core/app_config.cpp
)
target_include_directories(chunkvault_lib PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_link_libraries(chunkvault_lib PUBLIC
  Drogon::Drogon
  OpenSSL::SSL
  OpenSSL::Crypto
  jwt-cpp::jwt-cpp
  spdlog::spdlog
  nlohmann_json::nlohmann_json
)

add_executable(chunkvault src/main.cpp)
target_link_libraries(chunkvault PRIVATE chunkvault_lib)

add_subdirectory(tests)
