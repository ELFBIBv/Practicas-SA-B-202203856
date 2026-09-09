import os

# La app crea el cliente de Mongo al importarse (nivel de módulo), así que la
# variable de entorno debe apuntar al contenedor de servicio de MongoDB que el
# workflow de CI levanta antes de correr esta suite.
os.environ.setdefault("MONGO_URI", "mongodb://localhost:27017/catalog_db_test")

from fastapi.testclient import TestClient  # noqa: E402

from main import app  # noqa: E402

client = TestClient(app)


def _create_product(name="Teclado mecanico", price=350.5, stock=10):
    mutation = """
    mutation($name: String!, $description: String!, $price: Float!, $stock: Int!) {
        createProduct(name: $name, description: $description, price: $price, stock: $stock) {
            product { id name price stock }
        }
    }
    """
    variables = {"name": name, "description": "producto de prueba", "price": price, "stock": stock}
    response = client.post("/graphql", json={"query": mutation, "variables": variables})
    body = response.json()

    assert response.status_code == 200
    assert not body.get("errors")
    return body["data"]["createProduct"]["product"]


def test_health_endpoint():
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["status"] == "Catalog Service is running"


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
    )
    updated = response.json()["data"]["updateProductStock"]

    assert updated["stock"] == 3
