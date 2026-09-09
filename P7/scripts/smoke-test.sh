#!/usr/bin/env bash

set -euo pipefail

: "${P6_TEST_PASSWORD:?Define P6_TEST_PASSWORD con la contraseña efímera de prueba}"

namespace="${P6_NAMESPACE:-sa-p5}"
carnet="${P6_TEST_CARNET:-202203856}"
public_ip="${PUBLIC_IP:-$(kubectl get service sa-platform-api-gateway --namespace "$namespace" --output jsonpath='{.status.loadBalancer.ingress[0].ip}')}"
base_url="http://${public_ip}"

if [[ -z "$public_ip" ]]; then
  printf 'El API Gateway todavía no tiene una IP pública.\n' >&2
  exit 1
fi

printf 'API Gateway: %s\n' "$base_url"

curl --silent --show-error --fail --max-time 20 "$base_url/"
printf '\n'
curl --silent --show-error --fail --max-time 20 "$base_url/api/auth/health"
printf '\n'
curl --silent --show-error --fail --max-time 20 "$base_url/api/catalog/health"
printf '\n'
curl --silent --show-error --fail --max-time 20 "$base_url/api/orders/health"
printf '\n'

register_code=$(curl --silent --show-error --max-time 20 \
  --output /dev/null \
  --write-out '%{http_code}' \
  --request POST "$base_url/api/auth/register" \
  --header 'Content-Type: application/json' \
  --data "{\"carnet\":\"$carnet\",\"nombres\":\"Prueba\",\"apellidos\":\"P6\",\"correo\":\"p6-${carnet}@example.test\",\"password\":\"$P6_TEST_PASSWORD\",\"rol\":\"Admin\"}")

if [[ "$register_code" != "201" && "$register_code" != "409" ]]; then
  printf 'El registro devolvió HTTP %s; se esperaba 201 o 409.\n' "$register_code" >&2
  exit 1
fi

login_json=$(curl --silent --show-error --fail --max-time 20 \
  --request POST "$base_url/api/auth/login" \
  --header 'Content-Type: application/json' \
  --data "{\"carnet\":\"$carnet\",\"password\":\"$P6_TEST_PASSWORD\"}")

token=$(printf '%s' "$login_json" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$token" ]]; then
  printf 'El login no devolvió un token.\n' >&2
  exit 1
fi

validate_json=$(curl --silent --show-error --fail --max-time 20 \
  --request POST "$base_url/api/auth/validate" \
  --header "Authorization: Bearer $token" \
  --header 'Content-Type: application/json' \
  --data '{}')

product_json=$(curl --silent --show-error --fail --max-time 20 \
  --request POST "$base_url/api/catalog/graphql" \
  --header "Authorization: Bearer $token" \
  --header 'Content-Type: application/json' \
  --header 'X-REQUEST-TYPE: GraphQL' \
  --data '{"query":"mutation { createProduct(name: \"Producto smoke P6\", description: \"Prueba E2E AKS\", price: 25.50, stock: 10) { product { id name price stock } } }"}')

product_id=$(printf '%s' "$product_json" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$product_id" ]]; then
  printf 'Catalog no devolvió el ID del producto. Respuesta: %s\n' "$product_json" >&2
  exit 1
fi

order_payload=$(printf '{"query":"mutation { createOrder(userId: 1, productId: \\"%s\\", quantity: 2) { id total status createdAt } }"}' "$product_id")
order_json=$(curl --silent --show-error --fail --max-time 20 \
  --request POST "$base_url/api/orders/graphql" \
  --header "Authorization: Bearer $token" \
  --header 'Content-Type: application/json' \
  --header 'X-REQUEST-TYPE: GraphQL' \
  --data "$order_payload")

printf 'Registro HTTP: %s\n' "$register_code"
printf 'Validación JWT: %s\n' "$validate_json"
printf 'Producto: %s\n' "$product_json"
printf 'Pedido: %s\n' "$order_json"
printf 'Prueba E2E completada. Revise los logs de Notifications para confirmar el evento.\n'
