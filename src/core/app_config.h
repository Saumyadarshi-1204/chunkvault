#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace chunkvault {

struct AppConfig {
  std::string listen_address;
  std::uint16_t http_port;
  std::size_t thread_num;
  std::string log_level;

  static AppConfig FromEnvironment();
};

}  // namespace chunkvault
