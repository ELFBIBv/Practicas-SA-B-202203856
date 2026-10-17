// Prueba de carga contra el API Gateway de sa-platform.
// Uso local:   k6 run -e BASE_URL=http://localhost:8080 P8/loadtest/api-gateway-load-test.js
// Uso en CI:   ver el job "load-test" en .github/workflows/ci-cd.yml
import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

export const options = {
  stages: [
    { duration: "15s", target: 5 }, // calentamiento
    { duration: "30s", target: 20 }, // carga sostenida
    { duration: "15s", target: 0 }, // enfriamiento
  ],
  thresholds: {
    http_req_failed: ["rate<0.01"], // menos de 1% de requests fallidos
    http_req_duration: ["p(95)<500"], // 95% de las respuestas bajo 500ms
    // Sin esto, un check() fallido (ej. GraphQL devolviendo "errors" con
    // status 200) queda solo reportado mas no hace fallar la corrida.
    checks: ["rate>0.99"],
  },
};

export default function () {
  const health = http.get(`${BASE_URL}/health`);
  check(health, { "GET /health -> 200": (r) => r.status === 200 });

  // GraphQL responde 200 aunque el resolver haya fallado (el error queda
  // en el campo "errors" del body, no en el status HTTP) — verificar solo
  // el status code deja pasar fallos reales de backend sin que el umbral
  // los note. Se valida también que el body no traiga "errors".
  const catalogPayload = JSON.stringify({
    query: "{ products { id name price stock } }",
  });
  const catalogRes = http.post(`${BASE_URL}/api/catalog/graphql`, catalogPayload, {
    headers: { "Content-Type": "application/json" },
  });
  check(catalogRes, {
    "POST /api/catalog/graphql -> 200": (r) => r.status === 200,
    "POST /api/catalog/graphql -> sin errores de GraphQL": (r) => !JSON.parse(r.body).errors,
  });

  const ordersPayload = JSON.stringify({
    query: "{ orders { id status } }",
  });
  const ordersRes = http.post(`${BASE_URL}/api/orders/graphql`, ordersPayload, {
    headers: { "Content-Type": "application/json" },
  });
  check(ordersRes, {
    "POST /api/orders/graphql -> 200": (r) => r.status === 200,
    "POST /api/orders/graphql -> sin errores de GraphQL": (r) => !JSON.parse(r.body).errors,
  });

  sleep(1);
}
