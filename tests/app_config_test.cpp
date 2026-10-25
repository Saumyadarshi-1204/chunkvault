#include "core/app_config.h"

#include <gtest/gtest.h>

#include <cstdlib>

TEST(AppConfig, UsesDocumentedDefaultsWhenUnset) {
  ASSERT_EQ(unsetenv("CHUNKVAULT_LISTEN_ADDRESS"), 0);
  ASSERT_EQ(unsetenv("CHUNKVAULT_HTTP_PORT"), 0);
  ASSERT_EQ(unsetenv("CHUNKVAULT_THREAD_NUM"), 0);
  ASSERT_EQ(unsetenv("CHUNKVAULT_LOG_LEVEL"), 0);

  const auto config = chunkvault::AppConfig::FromEnvironment();

  EXPECT_EQ(config.listen_address, "0.0.0.0");
  EXPECT_EQ(config.http_port, 8080);
  EXPECT_EQ(config.thread_num, 0u);
  EXPECT_EQ(config.log_level, "info");
}
