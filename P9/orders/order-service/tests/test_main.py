import os
from unittest.mock import AsyncMock, MagicMock

# El workflow de CI levanta un contenedor de servicio MySQL con el esquema de
# orders/orders-db/init.sql ya aplicado antes de correr esta suite.
os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_PORT", "3306")
os.environ.setdefault("DB_USER", "root")
os.environ.setdefault("DB_PASSWORD", "root")
os.environ.setdefault("DB_NAME", "orders_db_test")
os.environ.setdefault("JWT_SECRET", "test-secret-solo-para-pytest-largo-32-bytes")

import jwt  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402

client = TestClient(main.app)


def _token(user_id: int, rol: str = "Cliente") -> str:
    return jwt.encode({"id": user_id, "rol": rol}, main.JWT_SECRET, algorithm="HS256")


AUTH_HEADERS = {"Authorization": f"Bearer {_token(1)}"}

CREATE_ORDER_MUTATION = """
mutation($productId: String!, $quantity: Int!) {
    createOrder(productId: $productId, quantity: $quantity) {
        id status total userId
    }
}
"""


def test_health_endpoint():
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "Orders Service is running"


def test_orders_query_returns_a_list():
    response = client.post("/graphql", json={"query": "query { orders { id status } }"})
    body = response.json()

    assert response.status_code == 200
    assert isinstance(body["data"]["orders"], list)


def test_create_order_requires_authentication():
    variables = {"productId": "prod-1", "quantity": 2}
    response = client.post("/graphql", json={"query": CREATE_ORDER_MUTATION, "variables": variables})
    body = response.json()

    assert body.get("errors"), "sin token debería rechazarse"


def test_create_order_calls_catalog_and_persists_order(monkeypatch):
    """create_order habla por HTTP con catalog y publica en NATS: ambas
    dependencias externas se simulan aqui, pero el INSERT/SELECT contra
    MySQL corre de verdad contra el contenedor de servicio de la CI."""

    def fake_post(url, json=None, timeout=None, headers=None):
        response = MagicMock()
        if "updateProductStock" in json["query"]:
            # Confirma que orders reenvía el Authorization del comprador,
            # no que llama a catalog sin credenciales.
            assert headers is not None and headers.get("Authorization") == AUTH_HEADERS["Authorization"]
            response.json.return_value = {"data": {"updateProductStock": {"id": "prod-1", "stock": 19}}}
        else:
            response.json.return_value = {"data": {"product": {"id": "prod-1", "price": 99.5}}}
        return response

    monkeypatch.setattr(main.httpx, "post", fake_post)
    monkeypatch.setattr(main.nats, "connect", AsyncMock(return_value=AsyncMock()))

    variables = {"productId": "prod-1", "quantity": 2}
    response = client.post("/graphql", json={"query": CREATE_ORDER_MUTATION, "variables": variables}, headers=AUTH_HEADERS)
    body = response.json()

    assert response.status_code == 200
    assert not body.get("errors")
    order = body["data"]["createOrder"]
    assert order["status"] == "PENDING"
    assert order["total"] == 199.0
    # El user_id viene del JWT (id=1 en _token), no de un argumento del
    # cliente — no hay ningún "userId" en las variables de la mutación.
    assert order["userId"] == 1


def test_create_order_rejects_when_catalog_reports_insufficient_stock(monkeypatch):
    """Si updateProductStock devuelve null (stock insuficiente, chequeo
    atómico en catalog), orders no debe crear la orden."""

    def fake_post(url, json=None, timeout=None, headers=None):
        response = MagicMock()
        if "updateProductStock" in json["query"]:
            response.json.return_value = {"data": {"updateProductStock": None}}
        else:
            response.json.return_value = {"data": {"product": {"id": "prod-1", "price": 99.5}}}
        return response

    monkeypatch.setattr(main.httpx, "post", fake_post)

    variables = {"productId": "prod-1", "quantity": 999}
    response = client.post("/graphql", json={"query": CREATE_ORDER_MUTATION, "variables": variables}, headers=AUTH_HEADERS)
    body = response.json()

    assert body.get("errors"), "stock insuficiente debería rechazar la orden, no crearla"
