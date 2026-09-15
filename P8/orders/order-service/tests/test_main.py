import os
from unittest.mock import AsyncMock, MagicMock

# El workflow de CI levanta un contenedor de servicio MySQL con el esquema de
# orders/orders-db/init.sql ya aplicado antes de correr esta suite.
os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_PORT", "3306")
os.environ.setdefault("DB_USER", "root")
os.environ.setdefault("DB_PASSWORD", "root")
os.environ.setdefault("DB_NAME", "orders_db_test")

from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402

client = TestClient(main.app)


def test_health_endpoint():
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "Orders Service is running"


def test_orders_query_returns_a_list():
    response = client.post("/graphql", json={"query": "query { orders { id status } }"})
    body = response.json()

    assert response.status_code == 200
    assert isinstance(body["data"]["orders"], list)


def test_create_order_calls_catalog_and_persists_order(monkeypatch):
    """create_order habla por HTTP con catalog y publica en NATS: ambas
    dependencias externas se simulan aqui, pero el INSERT/SELECT contra
    MySQL corre de verdad contra el contenedor de servicio de la CI."""

    def fake_post(url, json=None, timeout=None):
        response = MagicMock()
        if "updateProductStock" in json["query"]:
            response.json.return_value = {"data": {"updateProductStock": {"id": "prod-1", "stock": 19}}}
        else:
            response.json.return_value = {"data": {"product": {"id": "prod-1", "price": 99.5, "stock": 20}}}
        return response

    monkeypatch.setattr(main.httpx, "post", fake_post)
    monkeypatch.setattr(main.nats, "connect", AsyncMock(return_value=AsyncMock()))

    mutation = """
    mutation($userId: Int!, $productId: String!, $quantity: Int!) {
        createOrder(userId: $userId, productId: $productId, quantity: $quantity) {
            id status total
        }
    }
    """
    variables = {"userId": 1, "productId": "prod-1", "quantity": 2}
    response = client.post("/graphql", json={"query": mutation, "variables": variables})
    body = response.json()

    assert response.status_code == 200
    assert not body.get("errors")
    order = body["data"]["createOrder"]
    assert order["status"] == "PENDING"
    assert order["total"] == 199.0
