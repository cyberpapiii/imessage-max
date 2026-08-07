#!/usr/bin/env python3
"""Compare live per-tool input-schema hashes with the committed pin."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from mcp_http import DEFAULT_URL, LegacyClient


DEFAULT_PIN = Path(__file__).with_name("schema-hashes.json")


def sha256_json(value: Any) -> str:
    canonical = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check live MCP tool schemas against committed SHA-256 pins."
    )
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--pin", default=DEFAULT_PIN, type=Path)
    return parser.parse_args()


def load_pins(path: Path) -> dict[str, str]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("version") != 1 or document.get("algorithm") != "sha256":
        raise ValueError(f"unsupported pin format: {path}")
    tools = document.get("tools")
    if not isinstance(tools, dict) or not all(
        isinstance(name, str) and isinstance(digest, str)
        for name, digest in tools.items()
    ):
        raise ValueError(f"invalid tool pins: {path}")
    return tools


def fetch_hashes(url: str) -> dict[str, str]:
    client = LegacyClient(url=url)
    client.initialize()
    response = client.request("tools/list", {})
    if response.status != 200 or not isinstance(response.body, dict):
        raise RuntimeError(
            f"tools/list failed: HTTP {response.status} {response.body}"
        )
    result = response.body.get("result")
    tools = result.get("tools") if isinstance(result, dict) else None
    if not isinstance(tools, list):
        raise RuntimeError("tools/list response omitted result.tools")

    hashes: dict[str, str] = {}
    for tool in tools:
        if not isinstance(tool, dict) or not isinstance(tool.get("name"), str):
            raise RuntimeError("tools/list returned a malformed tool entry")
        name = tool["name"]
        if name in hashes:
            raise RuntimeError(f"tools/list returned duplicate tool: {name}")
        hashes[name] = sha256_json(tool.get("inputSchema", {}))
    return hashes


def main() -> int:
    args = parse_args()
    try:
        expected = load_pins(args.pin)
        observed = fetch_hashes(args.url)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"ERROR {error}")
        return 2

    failures = 0
    for name in sorted(expected.keys() | observed.keys()):
        expected_hash = expected.get(name)
        observed_hash = observed.get(name)
        if expected_hash is None:
            print(f"DRIFT {name}: unexpected live tool ({observed_hash})")
            failures += 1
        elif observed_hash is None:
            print(f"DRIFT {name}: pinned tool missing from live server")
            failures += 1
        elif expected_hash != observed_hash:
            print(
                f"DRIFT {name}: expected {expected_hash}, observed {observed_hash}"
            )
            failures += 1
        else:
            print(f"PASS {name} {observed_hash}")

    print(
        f"pinned={len(expected)} observed={len(observed)} drifted={failures}"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
