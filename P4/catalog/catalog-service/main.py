import os
import graphene
from fastapi import FastAPI
from starlette.graphql import GraphQLApp
from pymongo import MongoClient
from bson.objectid import ObjectId

app = FastAPI(title="Catalog Service")

MONGO_URI = os.getenv("MONGO_URI", "mongodb://localhost:27017/catalog_db")
client = MongoClient(MONGO_URI)
db = client.get_database()
products_collection = db.get_collection("products")

class ProductType(graphene.ObjectType):
    id = graphene.String()
    name = graphene.String()
    description = graphene.String()
    price = graphene.Float()
    stock = graphene.Int()

class Query(graphene.ObjectType):
    products = graphene.List(ProductType)
    product = graphene.Field(ProductType, id=graphene.String())

    def resolve_products(self, info):
        products = list(products_collection.find())
        return [ProductType(id=str(p["_id"]), name=p["name"], description=p["description"], price=p["price"], stock=p["stock"]) for p in products]

    def resolve_product(self, info, id):
        p = products_collection.find_one({"_id": ObjectId(id)})
        if p:
            return ProductType(id=str(p["_id"]), name=p["name"], description=p["description"], price=p["price"], stock=p["stock"])
        return None

class CreateProduct(graphene.Mutation):
    class Arguments:
        name = graphene.String(required=True)
        description = graphene.String(required=True)
        price = graphene.Float(required=True)
        stock = graphene.Int(required=True)

    product = graphene.Field(ProductType)

    def mutate(self, info, name, description, price, stock):
        new_product = {"name": name, "description": description, "price": price, "stock": stock}
        result = products_collection.insert_one(new_product)
        return CreateProduct(product=ProductType(id=str(result.inserted_id), name=name, description=description, price=price, stock=stock))

class Mutation(graphene.ObjectType):
    create_product = CreateProduct.Field()

schema = graphene.Schema(query=Query, mutation=Mutation)

# Endpoint de GraphQL usando Graphene
app.add_route("/graphql", GraphQLApp(schema=schema))

@app.get("/health")
def health():
    return {"status": "Catalog Service is running"}
