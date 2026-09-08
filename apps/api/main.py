from fastapi import FastAPI
import socket
import os

app = FastAPI()


@app.get("/")
def root():
    return {
        "message": "platform-engineering-lab",
        "hostname": socket.gethostname(),
        "version": os.getenv("APP_VERSION", "v1")
    }


@app.get("/health/live")
def liveness():
    return {"status": "alive"}


@app.get("/health/ready")
def readiness():
    return {"status": "ready"}
