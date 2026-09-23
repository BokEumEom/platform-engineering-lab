#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"

ENTRYPOINTS = [
    ROOT / "README.md",
    DOCS / "README.md",
    ROOT / "README.ko.md",
    DOCS / "ko" / "README.md",
    DOCS / "getting-started" / "README.md",
    DOCS / "evidence" / "README.md",
]

LINK_RE = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")


def require_files(paths: list[Path]) -> None:
    missing = [str(path.relative_to(ROOT)) for path in paths if not path.is_file()]
    if missing:
        raise SystemExit(f"missing required documentation entrypoints: {missing}")


def local_destination(raw: str) -> str | None:
    target = raw.strip().split()[0].strip("<>")
    if not target or target.startswith("#"):
        return None
    parsed = urlsplit(target)
    if parsed.scheme or parsed.netloc:
        return None
    return parsed.path or None


def validate_links(path: Path) -> int:
    checked = 0
    text = path.read_text(encoding="utf-8")
    for raw in LINK_RE.findall(text):
        destination = local_destination(raw)
        if destination is None:
            continue
        resolved = (path.parent / destination).resolve()
        try:
            resolved.relative_to(ROOT)
        except ValueError as exc:
            raise SystemExit(
                f"{path.relative_to(ROOT)} links outside the repository: {raw}"
            ) from exc
        if not resolved.exists():
            raise SystemExit(
                f"{path.relative_to(ROOT)} has missing local link target: {raw}"
            )
        checked += 1
    return checked


def require_indexed(index_path: Path, directory: Path) -> int:
    index = index_path.read_text(encoding="utf-8")
    documents = sorted(
        path for path in directory.glob("*.md")
        if path.name != "README.md"
    )
    missing = [path.name for path in documents if path.name not in index]
    if missing:
        raise SystemExit(
            f"{index_path.relative_to(ROOT)} must index Markdown files: {missing}"
        )
    return len(documents)


def require_text(path: Path, target: str) -> None:
    if target not in path.read_text(encoding="utf-8"):
        raise SystemExit(f"{path.relative_to(ROOT)} must link to {target}")


require_files(ENTRYPOINTS)

require_text(ROOT / "README.md", "docs/README.md")
require_text(ROOT / "README.ko.md", "docs/ko/README.md")
require_text(DOCS / "ko" / "README.md", "../../README.ko.md")

docs_index = (DOCS / "README.md").read_text(encoding="utf-8")
for child_index in (
    "getting-started/README.md",
    "evidence/README.md",
    "ko/README.md",
):
    if child_index not in docs_index:
        raise SystemExit(f"docs/README.md must link to {child_index}")

indexed = 0
indexed += require_indexed(DOCS / "README.md", DOCS)
indexed += require_indexed(DOCS / "getting-started" / "README.md", DOCS / "getting-started")
indexed += require_indexed(DOCS / "evidence" / "README.md", DOCS / "evidence")
indexed += require_indexed(DOCS / "ko" / "README.md", DOCS / "ko")

links = sum(validate_links(path) for path in ENTRYPOINTS)

print(
    "documentation structure guard passed: "
    f"entrypoints={len(ENTRYPOINTS)} indexed_documents={indexed} local_links={links}"
)
