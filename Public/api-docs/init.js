// Swagger UI for the WatchSwifty App API (spec: /api/openapi.yaml).
window.addEventListener("load", function () {
  window.ui = SwaggerUIBundle({
    url: "/api/openapi.yaml",
    dom_id: "#swagger-ui",
    persistAuthorization: true,
    deepLinking: true,
  });
});
