"""
ShopAPI — API de catálogo eCommerce
Laboratorio ECS SA Associate

Esta app es intencionalmente simple. El foco está en la infraestructura AWS,
no en la lógica de negocio.

Endpoints:
  GET  /health    → health check (para ALB y ECS)
  GET  /products  → lista de productos (mock o DynamoDB según config)
  POST /orders    → crea orden (publica en SQS)
  GET  /metrics   → info del container/entorno
"""

import os
import json
import socket
import logging
import boto3

from datetime import datetime
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "msg": "%(message)s"}',
)
logger = logging.getLogger(__name__)

# ── Config desde variables de entorno ───────────────────────────────────────
APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
APP_ENV     = os.getenv("APP_ENV", "development")
SQS_URL     = os.getenv("SQS_ORDERS_URL", "")       # URL de la cola SQS
USE_DYNAMO  = os.getenv("USE_DYNAMODB", "false").lower() == "true"
DYNAMO_TABLE = os.getenv("DYNAMO_TABLE", "shopapi-products")

# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="ShopAPI",
    description="API de catálogo eCommerce — Lab ECS SA Associate",
    version=APP_VERSION,
)

# ── Productos mock (v1-v2) ───────────────────────────────────────────────────
MOCK_PRODUCTS = [
    {"id": "p001", "name": "Laptop Pro 15", "price": 1299.99, "stock": 42},
    {"id": "p002", "name": "Wireless Mouse", "price":   29.99, "stock": 150},
    {"id": "p003", "name": "USB-C Hub",      "price":   49.99, "stock": 87},
    {"id": "p004", "name": "Monitor 4K 27",  "price":  399.99, "stock": 23},
    {"id": "p005", "name": "Mechanical Keyboard", "price": 149.99, "stock": 65},
]

# ── Modelos ───────────────────────────────────────────────────────────────────
class OrderRequest(BaseModel):
    product_id: str
    quantity: int
    customer_id: str

class OrderResponse(BaseModel):
    order_id: str
    status: str
    message: str

# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health")
def health_check():
    """Health check para ALB y ECS container health check."""
    return {
        "status": "ok",
        "version": APP_VERSION,
        "env": APP_ENV,
        "timestamp": datetime.utcnow().isoformat() + "Z",
    }


@app.get("/products")
def list_products():
    """Retorna lista de productos. Usa DynamoDB si USE_DYNAMODB=true, sino mock."""
    logger.info("GET /products")

    if USE_DYNAMO:
        try:
            dynamo = boto3.resource("dynamodb")
            table  = dynamo.Table(DYNAMO_TABLE)
            resp   = table.scan(Limit=50)
            return {"source": "dynamodb", "products": resp.get("Items", [])}
        except Exception as e:
            logger.error(f"Error DynamoDB: {e}")
            raise HTTPException(status_code=500, detail="Error accediendo a DynamoDB")

    return {"source": "mock", "products": MOCK_PRODUCTS}


@app.post("/orders", response_model=OrderResponse)
def create_order(order: OrderRequest):
    """Crea una orden y la publica en SQS si está configurado."""
    logger.info(f"POST /orders product={order.product_id} qty={order.quantity}")

    import uuid
    order_id = str(uuid.uuid4())[:8]
    message  = {
        "order_id":    order_id,
        "product_id":  order.product_id,
        "quantity":    order.quantity,
        "customer_id": order.customer_id,
        "created_at":  datetime.utcnow().isoformat() + "Z",
    }

    if SQS_URL:
        try:
            sqs = boto3.client("sqs")
            sqs.send_message(
                QueueUrl    = SQS_URL,
                MessageBody = json.dumps(message),
            )
            logger.info(f"Order {order_id} enviado a SQS")
            status = "queued"
        except Exception as e:
            logger.error(f"Error SQS: {e}")
            status = "error_sqs"
    else:
        logger.warning("SQS_ORDERS_URL no configurado; orden no encolada")
        status = "accepted_no_queue"

    return OrderResponse(
        order_id = order_id,
        status   = status,
        message  = f"Orden {order_id} procesada correctamente",
    )


@app.get("/metrics")
def metrics():
    """Info del entorno para debugging y observabilidad."""
    return {
        "hostname":    socket.gethostname(),
        "version":     APP_VERSION,
        "env":         APP_ENV,
        "dynamo":      USE_DYNAMO,
        "sqs_enabled": bool(SQS_URL),
        "timestamp":   datetime.utcnow().isoformat() + "Z",
    }
