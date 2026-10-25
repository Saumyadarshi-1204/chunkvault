#include "api/health_controller.h"
#include "core/app_config.h"

#include <drogon/drogon.h>
#include <spdlog/spdlog.h>

#include <stdexcept>
#include <string>

namespace {

spdlog::level::level_enum ParseLogLevel(const std::string& level) {
  if (level == "trace") {
    return spdlog::level::trace;
  }
  if (level == "debug") {
    return spdlog::level::debug;
  }
  if (level == "info") {
    return spdlog::level::info;
  }
  if (level == "warn" || level == "warning") {
    return spdlog::level::warn;
  }
  if (level == "error") {
    return spdlog::level::err;
  }
  if (level == "critical") {
    return spdlog::level::critical;
  }
  if (level == "off") {
    return spdlog::level::off;
  }
  return spdlog::level::info;
}

}  // namespace

int main() {
  try {
    const auto config = chunkvault::AppConfig::FromEnvironment();
    spdlog::set_level(ParseLogLevel(config.log_level));
    spdlog::info("starting chunkvault on {}:{}", config.listen_address,
                 config.http_port);

    chunkvault::api::RegisterHealthRoutes();

    auto& app = drogon::app();
    app.addListener(config.listen_address, config.http_port);
    if (config.thread_num > 0) {
      app.setThreadNum(config.thread_num);
    }
    app.run();
  } catch (const std::exception& ex) {
    spdlog::critical("failed to start: {}", ex.what());
    return 1;
  }
  return 0;
}
