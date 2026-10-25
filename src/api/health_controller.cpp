#include "api/health_controller.h"

#include <drogon/drogon.h>
#include <json/json.h>

namespace chunkvault::api {

void RegisterHealthRoutes() {
  drogon::app().registerHandler(
      "/health",
      [](const drogon::HttpRequestPtr&,
         std::function<void(const drogon::HttpResponsePtr&)>&& callback) {
        Json::Value body;
        body["status"] = "ok";
        auto response = drogon::HttpResponse::newHttpJsonResponse(body);
        response->setStatusCode(drogon::k200OK);
        callback(response);
      },
      {drogon::Get});
}

}  // namespace chunkvault::api
