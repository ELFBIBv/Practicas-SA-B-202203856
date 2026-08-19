import os
import strawberry
from fastapi import FastAPI
from strawberry.fastapi import GraphQLRouter
from pymongo import MongoClient
from bson.objectid import ObjectId

app = FastAPI(title="Catalog Service")

MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017/catalog_db")
client = MongoClient(MONGO_URI)
db = client.get_database()
products_collection = db.get_collection("products")

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
    def create_product(self, name: str, description: str, price: float, stock: int) -> CreateProductPayload:
        new_product = {"name": name, "description": description, "price": price, "stock": stock}
        result = products_collection.insert_one(new_product)
        prod = Product(id=str(result.inserted_id), name=name, description=description, price=price, stock=stock)
        return CreateProductPayload(product=prod)

schema = strawberry.Schema(query=Query, mutation=Mutation)
graphql_app = GraphQLRouter(schema)
app.include_router(graphql_app, prefix="/graphql")

@app.get("/health")
def health():
    return {"status": "Catalog Service is running"}
