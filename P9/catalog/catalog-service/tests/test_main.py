import os

# La app crea el cliente de Mongo al importarse (nivel de módulo), así que la
# variable de entorno debe apuntar al contenedor de servicio de MongoDB que el
# workflow de CI levanta antes de correr esta suite.
os.environ.setdefault("MONGO_URI", "mongodb://localhost:27017/catalog_db_test")
os.environ.setdefault("JWT_SECRET", "test-secret-solo-para-pytest-largo-32-bytes")

import jwt  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from main import app, JWT_SECRET  # noqa: E402

client = TestClient(app)


def _token(rol: str) -> str:
    return jwt.encode({"id": 1, "rol": rol}, JWT_SECRET, algorithm="HS256")


ADMIN_HEADERS = {"Authorization": f"Bearer {_token('Admin')}"}
CLIENTE_HEADERS = {"Authorization": f"Bearer {_token('Cliente')}"}


def _create_product(name="Teclado mecanico", price=350.5, stock=10, headers=ADMIN_HEADERS):
    mutation = """
    mutation($name: String!, $description: String!, $price: Float!, $stock: Int!) {
        createProduct(name: $name, description: $description, price: $price, stock: $stock) {
            product { id name price stock }
        }
    }
    """
    variables = {"name": name, "description": "producto de prueba", "price": price, "stock": stock}
    response = client.post("/graphql", json={"query": mutation, "variables": variables}, headers=headers)
    body = response.json()

    assert response.status_code == 200
    assert not body.get("errors")
    return body["data"]["createProduct"]["product"]


def test_health_endpoint():
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "Catalog Service is running"


def test_create_product_requires_admin_role():
    mutation = """
    mutation($name: String!, $description: String!, $price: Float!, $stock: Int!) {
        createProduct(name: $name, description: $description, price: $price, stock: $stock) {
            product { id }
        }
    }
    """
    variables = {"name": "x", "description": "x", "price": 1.0, "stock": 1}

    sin_token = client.post("/graphql", json={"query": mutation, "variables": variables})
    assert sin_token.json().get("errors"), "sin token debería rechazarse"

    con_token_cliente = client.post("/graphql", json={"query": mutation, "variables": variables}, headers=CLIENTE_HEADERS)
    assert con_token_cliente.json().get("errors"), "un Cliente (no Admin) no debería poder crear productos"


def test_create_and_query_product():
    product = _create_product()
    assert product["stock"] == 10

    query = """
    query($id: String!) {
        product(id: $id) { id name stock }
    }
    """
    response = client.post("/graphql", json={"query": query, "variables": {"id": product["id"]}})
    data = response.json()["data"]["product"]

    assert data["id"] == product["id"]
    assert data["name"] == "Teclado mecanico"


def test_update_product_stock_discounts_correctly():
    product = _create_product(name="Mouse", stock=5)
    mutation = """
    mutation($id: String!, $qty: Int!) {
        updateProductStock(id: $id, quantityToDiscount: $qty) { id stock }
    }
    """
    response = client.post(
        "/graphql",
        json={"query": mutation, "variables": {"id": product["id"], "qty": 2}},
        headers=CLIENTE_HEADERS,
    )
    updated = response.json()["data"]["updateProductStock"]

    assert updated["stock"] == 3


def test_update_product_stock_requires_authentication():
    product = _create_product(name="Teclado sin auth", stock=5)
    mutation = """
    mutation($id: String!, $qty: Int!) {
        updateProductStock(id: $id, quantityToDiscount: $qty) { id stock }
    }
    """
    response = client.post(
        "/graphql",
        json={"query": mutation, "variables": {"id": product["id"], "qty": 1}},
    )
    assert response.json().get("errors"), "sin token debería rechazarse"


def test_update_product_stock_rejects_insufficient_stock_atomically():
    product = _create_product(name="Stock bajo", stock=1)
    mutation = """
    mutation($id: String!, $qty: Int!) {
        updateProductStock(id: $id, quantityToDiscount: $qty) { id stock }
    }
    """
    response = client.post(
        "/graphql",
        json={"query": mutation, "variables": {"id": product["id"], "qty": 5}},
        headers=CLIENTE_HEADERS,
    )
    assert response.json()["data"]["updateProductStock"] is None


def test_update_product_stock_rejects_negative_quantity():
    product = _create_product(name="Cantidad negativa", stock=5)
    mutation = """
    mutation($id: String!, $qty: Int!) {
        updateProductStock(id: $id, quantityToDiscount: $qty) { id stock }
    }
    """
    response = client.post(
        "/graphql",
        json={"query": mutation, "variables": {"id": product["id"], "qty": -10}},
        headers=CLIENTE_HEADERS,
    )
    body = response.json()
    assert body.get("errors"), "una cantidad negativa no debería aumentar el stock"
