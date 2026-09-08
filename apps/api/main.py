from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
import socket
import os


def configure_tracing():
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        return None

    resource = Resource.create({
        "service.name": os.getenv("OTEL_SERVICE_NAME", "platform-api"),
        "service.version": os.getenv("APP_VERSION", "v1"),
        "deployment.environment.name": "local-lab",
    })

    tracer_provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(
        endpoint=endpoint,
        insecure=os.getenv("OTEL_EXPORTER_OTLP_INSECURE", "true").lower() == "true",
    )
    tracer_provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(tracer_provider)
    return tracer_provider


tracer_provider = configure_tracing()
app = FastAPI()

if tracer_provider is not None:
    FastAPIInstrumentor.instrument_app(
        app,
        tracer_provider=tracer_provider,
        excluded_urls=".*/metrics,.*/health/live,.*/health/ready",
        exclude_spans=["receive", "send"],
    )

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
