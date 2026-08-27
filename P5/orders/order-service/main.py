import os
import strawberry
from fastapi import FastAPI
from strawberry.fastapi import GraphQLRouter
import mysql.connector
import httpx
import nats
import asyncio
import json
app = FastAPI(title="Orders Service")

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "postgres")
DB_NAME = os.getenv("DB_NAME", "orders_db")

def get_db():
    return mysql.connector.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASSWORD, database=DB_NAME
    )

@strawberry.type
class OrderItem:
    id: int
    order_id: int
    product_id: str
    quantity: int
    unit_price: float

@strawberry.type
class Order:
    id: int
    user_id: int
    total: float
    status: str
    created_at: str

@strawberry.type
class Query:
    @strawberry.field
    def orders(self) -> list[Order]:
        conn = get_db()
        cur = conn.cursor(dictionary=True)
        cur.execute("SELECT * FROM orders")
        rows = cur.fetchall()
        conn.close()
        return [Order(id=r['id'], user_id=r['user_id'], total=r['total'], status=r['status'], created_at=str(r['created_at'])) for r in rows]

@strawberry.type
class Mutation:
    @strawberry.mutation
    def create_order(self, user_id: int, product_id: str, quantity: int) -> Order:
        # 1. Consultar el servicio de catálogo para validar y obtener precio/stock
        catalog_url = os.getenv("CATALOG_SERVICE_URL", "http://catalog-service:8000/graphql")
        
        query = """
        query($id: String!) {
            product(id: $id) {
                id
                price
                stock
            }
        }
        """
        try:
            res = httpx.post(catalog_url, json={"query": query, "variables": {"id": product_id}}, timeout=5.0)
            res_data = res.json()
            product_data = res_data.get("data", {}).get("product")
            
            if not product_data:
                raise Exception("El producto no existe en el catálogo.")
            if product_data["stock"] < quantity:
                raise Exception(f"Stock insuficiente. Stock actual: {product_data['stock']}")
                
            # Usar el precio oficial en lugar del proporcionado por el usuario
            official_unit_price = product_data["price"]
        except httpx.RequestError as e:
            raise Exception(f"Error al comunicarse con el catálogo: {str(e)}")

        # 2. Descontar stock en el catálogo
        mutation = """
        mutation($id: String!, $qty: Int!) {
            updateProductStock(id: $id, quantityToDiscount: $qty) {
                id
                stock
            }
        }
        """
        try:
            res_mut = httpx.post(catalog_url, json={"query": mutation, "variables": {"id": product_id, "qty": quantity}}, timeout=5.0)
            res_mut_data = res_mut.json()
            if res_mut_data.get("errors"):
                raise Exception(f"Error al descontar el stock: {res_mut_data['errors']}")
        except httpx.RequestError as e:
            raise Exception(f"Error al descontar stock en el catálogo: {str(e)}")

        # 3. Guardar orden en base de datos
        conn = get_db()
        cur = conn.cursor(dictionary=True)
        total = quantity * official_unit_price
        
        # 4. Insertar orden
        cur.execute("INSERT INTO orders (user_id, total, status) VALUES (%s, %s, %s)", (user_id, total, "PENDING"))
        order_id = cur.lastrowid
        
        cur.execute("SELECT created_at FROM orders WHERE id = %s", (order_id,))
        order_record = cur.fetchone()
        created_at = order_record['created_at']
        
        # 5. Insertar detalle de orden
        cur.execute("INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (%s, %s, %s, %s)", (order_id, product_id, quantity, official_unit_price))
        
        conn.commit()
        conn.close()

        # 3. Llamar al servicio de notificaciones asíncronamente con NATS
        nats_url = os.getenv("NATS_URL", "nats://sa-platform-nats:4222")
        
        async def publish_event():
            try:
                nc = await nats.connect(nats_url)
                await nc.publish("orders.created", json.dumps({"event": "ORDER_CREATED", "order_id": order_id}).encode())
                await nc.close()
            except Exception as e:
                print("No se pudo enviar la notificación a NATS:", e)
        
        # Como estamos en una función síncrona, usamos asyncio para ejecutar
        try:
            loop = asyncio.get_running_loop()
            loop.create_task(publish_event())
        except RuntimeError:
            asyncio.run(publish_event())

        return Order(id=order_id, user_id=user_id, total=total, status="PENDING", created_at=str(created_at))

schema = strawberry.Schema(query=Query, mutation=Mutation)
graphql_app = GraphQLRouter(schema)
app.include_router(graphql_app, prefix="/graphql")

@app.get("/health")
def health():
    return {"status": "Orders Service is running"}

@app.get("/")
def read_root():
    return {"status": "OK"}
