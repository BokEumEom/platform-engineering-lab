from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator
import socket
import os

app = FastAPI()

Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)


@app.get("/")
def root():
    return {
        "message": "platform-engineering-lab GitOps",
        "hostname": socket.gethostname(),
        "version": os.getenv("APP_VERSION", "v1")
    }


@app.get("/health/live")
def liveness():
    return {"status": "alive"}


@app.get("/health/ready")
def readiness():
    return {"status": "ready"}
