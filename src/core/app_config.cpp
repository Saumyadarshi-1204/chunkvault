#include "core/app_config.h"

#include <cstdlib>
#include <stdexcept>
#include <string>

namespace chunkvault {
namespace {

std::string EnvOr(const char* name, const char* fallback) {
  const char* value = std::getenv(name);
  if (value == nullptr || value[0] == '\0') {
    return fallback;
  }
  return value;
}

std::uint16_t ParsePort(const std::string& value) {
  int port = 0;
  try {
    port = std::stoi(value);
  } catch (const std::exception&) {
    throw std::invalid_argument("CHUNKVAULT_HTTP_PORT must be an integer");
  }
  if (port < 1 || port > 65535) {
    throw std::invalid_argument(
        "CHUNKVAULT_HTTP_PORT must be between 1 and 65535");
  }
  return static_cast<std::uint16_t>(port);
}

std::size_t ParseThreadNum(const std::string& value) {
  try {
    const long parsed = std::stol(value);
    if (parsed < 0) {
      throw std::invalid_argument("CHUNKVAULT_THREAD_NUM must be >= 0");
    }
    return static_cast<std::size_t>(parsed);
  } catch (const std::invalid_argument&) {
    throw;
  } catch (const std::exception&) {
    throw std::invalid_argument("CHUNKVAULT_THREAD_NUM must be an integer");
  }
}

}  // namespace

AppConfig AppConfig::FromEnvironment() {
  AppConfig config;
  config.listen_address = EnvOr("CHUNKVAULT_LISTEN_ADDRESS", "0.0.0.0");
  config.http_port = ParsePort(EnvOr("CHUNKVAULT_HTTP_PORT", "8080"));
  config.thread_num = ParseThreadNum(EnvOr("CHUNKVAULT_THREAD_NUM", "0"));
  config.log_level = EnvOr("CHUNKVAULT_LOG_LEVEL", "info");
  return config;
}

}  // namespace chunkvault
