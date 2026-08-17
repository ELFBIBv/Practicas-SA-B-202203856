import os
import strawberry
from fastapi import FastAPI
from strawberry.fastapi import GraphQLRouter
import psycopg2
from psycopg2.extras import RealDictCursor
import httpx

app = FastAPI(title="Orders Service")

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_USER = os.getenv("DB_USER", "postgres")
DB_PASSWORD = os.getenv("DB_PASSWORD", "postgres")
DB_NAME = os.getenv("DB_NAME", "orders_db")

def get_db():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASSWORD, dbname=DB_NAME,
        cursor_factory=RealDictCursor
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
        cur = conn.cursor()
        cur.execute("SELECT * FROM orders")
        rows = cur.fetchall()
        conn.close()
        return [Order(id=r['id'], user_id=r['user_id'], total=r['total'], status=r['status'], created_at=str(r['created_at'])) for r in rows]

@strawberry.type
class Mutation:
    @strawberry.mutation
    def create_order(self, user_id: int, product_id: str, quantity: int, unit_price: float) -> Order:
        conn = get_db()
        cur = conn.cursor()
        total = quantity * unit_price
        
        # 1. Insertar orden
        cur.execute("INSERT INTO orders (user_id, total, status) VALUES (%s, %s, %s) RETURNING id, created_at", (user_id, total, "PENDING"))
        order_record = cur.fetchone()
        order_id = order_record['id']
        created_at = order_record['created_at']
        
        # 2. Insertar detalle de orden
        cur.execute("INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (%s, %s, %s, %s)", (order_id, product_id, quantity, unit_price))
        
        conn.commit()
        conn.close()

        # 3. Llamar al servicio de notificaciones
        notif_url = os.getenv("NOTIFICATION_SERVICE_URL", "http://notification-service:8080")
        try:
            httpx.post(f"{notif_url}/api/notifications", json={"event": "ORDER_CREATED", "order_id": order_id})
        except Exception as e:
            print("No se pudo enviar la notificación:", e)

        return Order(id=order_id, user_id=user_id, total=total, status="PENDING", created_at=str(created_at))

schema = strawberry.Schema(query=Query, mutation=Mutation)
graphql_app = GraphQLRouter(schema)
app.include_router(graphql_app, prefix="/graphql")

@app.get("/health")
def health():
    return {"status": "Orders Service is running"}
