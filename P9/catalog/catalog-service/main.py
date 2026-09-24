import os
import jwt
import strawberry
from fastapi import FastAPI
from strawberry.fastapi import GraphQLRouter
from pymongo import MongoClient, ReturnDocument
from bson.objectid import ObjectId

app = FastAPI(title="Catalog Service")

MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017/catalog_db")
JWT_SECRET = os.getenv("JWT_SECRET", "supersecret123")
client = MongoClient(MONGO_URI)
db = client.get_database()
products_collection = db.get_collection("products")


def _authenticated_role(info: strawberry.types.Info) -> str | None:
    """Decodifica el JWT del header Authorization (mismo secreto que usa
    auth-service para firmarlo) y devuelve el rol, o None si no hay token
    válido. No llama a auth-service por HTTP: verifica la firma localmente."""
    request = info.context["request"]
    auth_header = request.headers.get("authorization", "")
    if not auth_header.startswith("Bearer "):
        return None
    try:
        payload = jwt.decode(auth_header[len("Bearer "):], JWT_SECRET, algorithms=["HS256"])
    except jwt.PyJWTError:
        return None
    return payload.get("rol")


def _require_admin(info: strawberry.types.Info) -> None:
    if _authenticated_role(info) != "Admin":
        raise Exception("Se requiere autenticación con rol Admin para esta operación.")


def _require_authenticated(info: strawberry.types.Info) -> None:
    if _authenticated_role(info) is None:
        raise Exception("Se requiere autenticación para esta operación.")


@strawberry.type
class Product:
    id: str
    name: str
    description: str
    price: float
    stock: int

@strawberry.type
class CreateProductPayload:
    product: Product

@strawberry.type
class Query:
    @strawberry.field
    def products(self) -> list[Product]:
        products = list(products_collection.find())
        return [Product(id=str(p["_id"]), name=p["name"], description=p["description"], price=p["price"], stock=p["stock"]) for p in products]

    @strawberry.field
    def product(self, id: str) -> Product | None:
        p = products_collection.find_one({"_id": ObjectId(id)})
        if p:
            return Product(id=str(p["_id"]), name=p["name"], description=p["description"], price=p["price"], stock=p["stock"])
        return None

@strawberry.type
class Mutation:
    @strawberry.mutation
    def create_product(self, info: strawberry.types.Info, name: str, description: str, price: float, stock: int) -> CreateProductPayload:
        _require_admin(info)
        new_product = {"name": name, "description": description, "price": price, "stock": stock}
        result = products_collection.insert_one(new_product)
        prod = Product(id=str(result.inserted_id), name=name, description=description, price=price, stock=stock)
        return CreateProductPayload(product=prod)

    @strawberry.mutation
    def update_product_stock(self, info: strawberry.types.Info, id: str, quantity_to_discount: int) -> Product | None:
        # No exige rol Admin: la llama orders-service en nombre de un
        # Cliente autenticado durante el checkout, no es una operación de
        # gestión de catálogo. Sí exige que haya alguien autenticado detrás
        # (orders-service reenvía el Authorization del comprador).
        _require_authenticated(info)
        if quantity_to_discount < 0:
            raise Exception("quantity_to_discount no puede ser negativo.")
        # Atómico: el propio find_one_and_update exige stock suficiente
        # como parte del filtro, no en un paso separado. Dos compras
        # concurrentes ya no pueden pasar ambas la validación con el mismo
        # stock leído de antemano — solo una gana la condición atómica, la
        # otra recibe None (orders-service lo trata como "stock
        # insuficiente" y no crea la orden).
        result = products_collection.find_one_and_update(
            {"_id": ObjectId(id), "stock": {"$gte": quantity_to_discount}},
            {"$inc": {"stock": -quantity_to_discount}},
            return_document=ReturnDocument.AFTER
        )
        if result:
            return Product(id=str(result["_id"]), name=result["name"], description=result["description"], price=result["price"], stock=result["stock"])
        return None

schema = strawberry.Schema(query=Query, mutation=Mutation)
graphql_app = GraphQLRouter(schema)
app.include_router(graphql_app, prefix="/graphql")

@app.get("/health")
def health():
    return {"status": "Catalog Service is running"}

@app.get("/")
def read_root():
    return {"status": "OK"}
