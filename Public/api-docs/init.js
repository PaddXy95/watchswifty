// Swagger UI for the WatchSwifty App API (spec: /api/openapi.yaml).
// A pasted bearer token stays in memory only: localStorage would keep it for anyone using this browser later.
window.addEventListener("load", function () {
  try { localStorage.removeItem("authorized"); } catch (e) {} // token stored by earlier versions
  window.ui = SwaggerUIBundle({
    url: "/api/openapi.yaml",
    dom_id: "#swagger-ui",
    persistAuthorization: false,
    deepLinking: true,
  });
});
