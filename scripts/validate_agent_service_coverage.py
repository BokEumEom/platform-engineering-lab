#!/usr/bin/env python3
"""Validate that every GitOps application service has Agent Prometheus evidence coverage."""
from __future__ import annotations

import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "gitops" / "apps" / "demo-app"
QUERY_FILE = ROOT / "observability" / "agent-prometheus-queries.json"
REQUIRED_SIGNALS = {
    "target_up",
    "request_rate_5m",
    "error_ratio_5m",
    "p95_latency_seconds_5m",
}


def deployment_services() -> set[str]:
    services: set[str] = set()
    for path in sorted(APP_DIR.glob("*.yaml")):
        for doc in yaml.safe_load_all(path.read_text(encoding="utf-8")):
            if not isinstance(doc, dict) or doc.get("kind") != "Deployment":
                continue
            if (doc.get("metadata") or {}).get("namespace") != "demo-app":
                continue
            containers = (((doc.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []
            found: list[str] = []
            for container in containers:
                for env in (container or {}).get("env") or []:
                    if env.get("name") == "OTEL_SERVICE_NAME" and isinstance(env.get("value"), str):
                        found.append(env["value"])
            name = (doc.get("metadata") or {}).get("name", "<unknown>")
            if len(found) != 1:
                raise SystemExit(f"Deployment {name} must define exactly one literal OTEL_SERVICE_NAME; found {found}")
            services.add(found[0])
    if not services:
        raise SystemExit("no demo-app Deployment OTEL_SERVICE_NAME values found")
    return services


def main() -> int:
    services = deployment_services()
    profile = json.loads(QUERY_FILE.read_text(encoding="utf-8"))
    by_component_signal: dict[tuple[str, str], list[tuple[str, dict]]] = {}
    for qid, spec in profile.items():
        if not isinstance(spec, dict):
            raise SystemExit(f"query {qid} must be an object")
        component = spec.get("component")
        signal = spec.get("signal")
        if isinstance(component, str) and isinstance(signal, str):
            by_component_signal.setdefault((component, signal), []).append((qid, spec))

    errors: list[str] = []
    for service in sorted(services):
        for signal in sorted(REQUIRED_SIGNALS):
            matches = by_component_signal.get((service, signal), [])
            if len(matches) != 1:
                errors.append(f"{service}: expected exactly one {signal} query, found {len(matches)}")
                continue
            qid, spec = matches[0]
            query = str(spec.get("query") or "")
            selector = f'platform_service="{service}"'
            if selector not in query:
                errors.append(f"{qid}: query must scope evidence with {selector}")

    if errors:
        raise SystemExit("Agent service evidence coverage failed:\n- " + "\n- ".join(errors))

    print("Agent service evidence coverage passed")
    print("services: " + ", ".join(sorted(services)))
    print("required signals: " + ", ".join(sorted(REQUIRED_SIGNALS)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
