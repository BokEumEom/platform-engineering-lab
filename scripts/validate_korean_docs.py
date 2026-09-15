#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED = [
    ROOT / "README.ko.md",
    ROOT / "docs/ko/README.md",
    ROOT / "docs/ko/20-multi-signal-observability.md",
    ROOT / "docs/ko/21-kubernetes-operating-environment.md",
    ROOT / "docs/ko/22-cilium-hubble-roadmap.md",
]

missing = [str(path.relative_to(ROOT)) for path in REQUIRED if not path.is_file()]
if missing:
    raise SystemExit(f"missing required Korean documentation: {missing}")

ko_readme = (ROOT / "README.ko.md").read_text(encoding="utf-8")
for target in (
    "docs/ko/README.md",
    "docs/ko/20-multi-signal-observability.md",
    "docs/ko/21-kubernetes-operating-environment.md",
    "docs/ko/22-cilium-hubble-roadmap.md",
):
    if target not in ko_readme:
        raise SystemExit(f"README.ko.md must link to {target}")

index = (ROOT / "docs/ko/README.md").read_text(encoding="utf-8")
if "README.ko.md" not in index:
    raise SystemExit("docs/ko/README.md must link back to README.ko.md")

print("Korean documentation entrypoint guard passed")
