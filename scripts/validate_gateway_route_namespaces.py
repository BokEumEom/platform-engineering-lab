from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]
PLATFORM = ROOT / "gitops" / "platform"


def load_docs(path: Path):
    return [doc for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")) if isinstance(doc, dict)]


namespace_labels = {}
for path in PLATFORM.glob("*.yaml"):
    for doc in load_docs(path):
        if doc.get("kind") == "Namespace":
            metadata = doc.get("metadata") or {}
            namespace_labels[str(metadata.get("name"))] = metadata.get("labels") or {}

routes = []
for path in PLATFORM.glob("*.yaml"):
    for doc in load_docs(path):
        if doc.get("kind") != "HTTPRoute":
            continue
        metadata = doc.get("metadata") or {}
        spec = doc.get("spec") or {}
        for parent in spec.get("parentRefs", []):
            if parent.get("name") == "platform-gateway":
                routes.append((path.name, str(metadata.get("name")), str(metadata.get("namespace") or "platform-system")))

if not routes:
    raise SystemExit("no HTTPRoutes target platform-gateway")

missing = []
for filename, route_name, namespace in routes:
    labels = namespace_labels.get(namespace, {})
    if labels.get("gateway-access") != "true":
        missing.append(f"{filename}:{route_name} namespace={namespace}")

if missing:
    raise SystemExit(
        "HTTPRoute namespaces must be declared with gateway-access=true to satisfy Gateway allowedRoutes: "
        + ", ".join(sorted(missing))
    )

print(f"gateway route namespace guard passed for {len(routes)} routes")
