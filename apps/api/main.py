from __future__ import annotations

import asyncio
import json
import os
import random
import socket
import time
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from prometheus_fastapi_instrumentator import Instrumentator
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


SERVICE_ROLE = os.getenv("SERVICE_ROLE", "gateway")
SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "platform-api")
APP_VERSION = os.getenv("APP_VERSION", "v1")
CATALOG_URL = os.getenv("CATALOG_URL", "http://catalog.demo-app.svc.cluster.local")
ORDERS_URL = os.getenv("ORDERS_URL", "http://orders.demo-app.svc.cluster.local")
INVENTORY_URL = os.getenv("INVENTORY_URL", "http://inventory.demo-app.svc.cluster.local")
PAYMENTS_URL = os.getenv("PAYMENTS_URL", "http://payments.demo-app.svc.cluster.local")
RECOMMENDATIONS_URL = os.getenv(
    "RECOMMENDATIONS_URL",
    "http://recommendations.demo-app.svc.cluster.local",
)
DOWNSTREAM_TIMEOUT_SECONDS = float(os.getenv("DOWNSTREAM_TIMEOUT_SECONDS", "2.0"))
FAULT_LATENCY_MS = max(0, int(os.getenv("FAULT_LATENCY_MS", "0")))
FAULT_ERROR_RATE_PERCENT = min(
    100.0,
    max(0.0, float(os.getenv("FAULT_ERROR_RATE_PERCENT", "0"))),
)


def configure_tracing() -> TracerProvider | None:
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        return None

    resource = Resource.create({
        "service.name": SERVICE_NAME,
        "service.version": APP_VERSION,
        "deployment.environment.name": "local-lab",
        "service.namespace": "platform-demo",
        "service.instance.id": socket.gethostname(),
    })

    tracer_provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(
        endpoint=endpoint,
        insecure=os.getenv("OTEL_EXPORTER_OTLP_INSECURE", "true").lower() == "true",
    )
    tracer_provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(tracer_provider)
    return tracer_provider


def trace_fields() -> dict[str, str]:
    context = trace.get_current_span().get_span_context()
    if not context.is_valid:
        return {"trace_id": "", "span_id": ""}
    return {
        "trace_id": format(context.trace_id, "032x"),
        "span_id": format(context.span_id, "016x"),
    }


def emit_log(level: str, event: str, **fields: Any) -> None:
    payload = {
        "timestamp": time.time(),
        "level": level,
        "event": event,
        "service": SERVICE_NAME,
        "service_role": SERVICE_ROLE,
        "version": APP_VERSION,
        "hostname": socket.gethostname(),
        **trace_fields(),
        **fields,
    }
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


async def apply_fault_policy() -> None:
    if FAULT_LATENCY_MS:
        await asyncio.sleep(FAULT_LATENCY_MS / 1000)
    if FAULT_ERROR_RATE_PERCENT and random.random() * 100 < FAULT_ERROR_RATE_PERCENT:
        raise HTTPException(status_code=503, detail=f"injected failure from {SERVICE_NAME}")


tracer_provider = configure_tracing()
app = FastAPI(title=SERVICE_NAME)

if tracer_provider is not None:
    FastAPIInstrumentor.instrument_app(
        app,
        tracer_provider=tracer_provider,
        excluded_urls=".*/metrics,.*/health/live,.*/health/ready",
        exclude_spans=["receive", "send"],
    )
    HTTPXClientInstrumentor().instrument(tracer_provider=tracer_provider)

Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)


@app.middleware("http")
async def structured_request_log(request: Request, call_next):
    started = time.perf_counter()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    except Exception:
        emit_log(
            "error",
            "http_request_failed",
            method=request.method,
            path=request.url.path,
            duration_ms=round((time.perf_counter() - started) * 1000, 2),
        )
        raise
    finally:
        emit_log(
            "info" if status_code < 500 else "error",
            "http_request_completed",
            method=request.method,
            path=request.url.path,
            status=status_code,
            duration_ms=round((time.perf_counter() - started) * 1000, 2),
        )


async def get_json(client: httpx.AsyncClient, url: str) -> dict[str, Any]:
    response = await client.get(url)
    response.raise_for_status()
    return response.json()


async def fetch_dependencies(targets: dict[str, str]) -> dict[str, dict[str, Any]]:
    timeout = httpx.Timeout(DOWNSTREAM_TIMEOUT_SECONDS)
    async with httpx.AsyncClient(timeout=timeout) as client:
        names = list(targets)
        results = await asyncio.gather(
            *(get_json(client, targets[name]) for name in names),
        )
    return dict(zip(names, results, strict=True))


@app.get("/")
async def root():
    await apply_fault_policy()

    if SERVICE_ROLE != "gateway":
        return {
            "message": "platform-engineering-lab service",
            "service": SERVICE_NAME,
            "role": SERVICE_ROLE,
            "hostname": socket.gethostname(),
            "version": APP_VERSION,
        }

    started = time.perf_counter()
    try:
        dependencies = await fetch_dependencies({
            "catalog": f"{CATALOG_URL}/catalog",
            "orders": f"{ORDERS_URL}/orders",
            "recommendations": f"{RECOMMENDATIONS_URL}/recommendations",
        })
    except (httpx.HTTPError, asyncio.TimeoutError) as exc:
        emit_log("error", "downstream_request_failed", error=str(exc))
        raise HTTPException(status_code=502, detail="downstream dependency unavailable") from exc

    return {
        "message": "platform-engineering-lab operational reference environment",
        "service": SERVICE_NAME,
        "hostname": socket.gethostname(),
        "version": APP_VERSION,
        "duration_ms": round((time.perf_counter() - started) * 1000, 2),
        "dependencies": dependencies,
    }


@app.get("/catalog")
async def catalog():
    if SERVICE_ROLE != "catalog":
        raise HTTPException(status_code=404, detail="catalog endpoint unavailable for this service role")
    await apply_fault_policy()
    return {
        "service": SERVICE_NAME,
        "items": 42,
        "status": "available",
        "version": APP_VERSION,
    }


@app.get("/orders")
async def orders():
    if SERVICE_ROLE != "orders":
        raise HTTPException(status_code=404, detail="orders endpoint unavailable for this service role")
    await apply_fault_policy()
    try:
        dependencies = await fetch_dependencies({
            "inventory": f"{INVENTORY_URL}/inventory",
            "payments": f"{PAYMENTS_URL}/payments",
        })
    except (httpx.HTTPError, asyncio.TimeoutError) as exc:
        emit_log("error", "orders_dependency_failed", error=str(exc))
        raise HTTPException(status_code=502, detail="orders dependency unavailable") from exc
    return {
        "service": SERVICE_NAME,
        "open_orders": 7,
        "status": "available",
        "version": APP_VERSION,
        "dependencies": dependencies,
    }


@app.get("/inventory")
async def inventory():
    if SERVICE_ROLE != "inventory":
        raise HTTPException(status_code=404, detail="inventory endpoint unavailable for this service role")
    await apply_fault_policy()
    return {
        "service": SERVICE_NAME,
        "available_skus": 37,
        "reserved_skus": 5,
        "status": "available",
        "version": APP_VERSION,
    }


@app.get("/payments")
async def payments():
    if SERVICE_ROLE != "payments":
        raise HTTPException(status_code=404, detail="payments endpoint unavailable for this service role")
    await apply_fault_policy()
    return {
        "service": SERVICE_NAME,
        "authorization": "ready",
        "provider": "reference-sandbox",
        "status": "available",
        "version": APP_VERSION,
    }


@app.get("/recommendations")
async def recommendations():
    if SERVICE_ROLE != "recommendations":
        raise HTTPException(status_code=404, detail="recommendations endpoint unavailable for this service role")
    await apply_fault_policy()
    return {
        "service": SERVICE_NAME,
        "recommended_skus": ["sku-101", "sku-204", "sku-305"],
        "status": "available",
        "version": APP_VERSION,
    }


def dependency_targets() -> dict[str, str]:
    if SERVICE_ROLE == "gateway":
        return {
            "catalog": f"{CATALOG_URL}/health/ready",
            "orders": f"{ORDERS_URL}/health/ready",
            "recommendations": f"{RECOMMENDATIONS_URL}/health/ready",
        }
    if SERVICE_ROLE == "orders":
        return {
            "inventory": f"{INVENTORY_URL}/health/ready",
            "payments": f"{PAYMENTS_URL}/health/ready",
        }
    return {}


@app.get("/dependency-health")
async def dependency_health():
    targets = dependency_targets()
    if not targets:
        return {"service": SERVICE_NAME, "dependencies": {}}

    results: dict[str, Any] = {}
    async with httpx.AsyncClient(timeout=httpx.Timeout(DOWNSTREAM_TIMEOUT_SECONDS)) as client:
        for name, url in targets.items():
            try:
                response = await client.get(url)
                results[name] = {"status": response.status_code, "healthy": response.is_success}
            except httpx.HTTPError as exc:
                results[name] = {"status": None, "healthy": False, "error": str(exc)}
    return {"service": SERVICE_NAME, "dependencies": results}


@app.get("/health/live")
def liveness():
    return {"status": "alive", "service": SERVICE_NAME}


@app.get("/health/ready")
def readiness():
    return {"status": "ready", "service": SERVICE_NAME}
