#!/usr/bin/env python3
"""Replay G0-01 read-path golden requests against the live server."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from mcp_http import LegacyClient


def is_successful_tool_response(body: dict[str, Any] | None) -> bool:
    if not isinstance(body, dict) or "error" in body:
        return False
    result = body.get("result")
    return isinstance(result, dict) and result.get("isError") is not True


def error_code(body: dict[str, Any] | None) -> str | None:
    if not isinstance(body, dict):
        return None
    result = body.get("result")
    content = result.get("content") if isinstance(result, dict) else None
    if not isinstance(content, list) or not content:
        return None
    first = content[0]
    if not isinstance(first, dict) or not isinstance(first.get("text"), str):
        return None
    try:
        parsed = json.loads(first["text"])
    except json.JSONDecodeError:
        return None
    value = parsed.get("error")
    return value if isinstance(value, str) else None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixtures-dir", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    fixture_paths = sorted(args.fixtures_dir.glob("[0-9][0-9]-*.json"))
    if len(fixture_paths) < 5:
        print(f"FAIL expected at least 5 fixtures, found {len(fixture_paths)}")
        return 1

    client = LegacyClient()
    client.initialize()
    failures = 0
    for fixture_path in fixture_paths:
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        params = fixture["request"]["params"]
        tool_name = params["name"]
        if tool_name == "send":
            print(f"FAIL {fixture_path.name}: send is forbidden")
            failures += 1
            continue

        result = client.call_tool(tool_name, params.get("arguments", {}))
        expected_status = fixture["expected"]["http_status"]
        expected_is_error = fixture["expected"]["is_error"]
        observed_is_error = not is_successful_tool_response(result.body)
        expected_error_code = fixture["expected"].get("error_code")
        passed = (
            result.status == expected_status
            and observed_is_error == expected_is_error
            and error_code(result.body) == expected_error_code
        )
        print(
            f"{'PASS' if passed else 'FAIL'} {fixture_path.name} "
            f"http={result.status} is_error={observed_is_error} "
            f"error_code={error_code(result.body)}"
        )
        failures += 0 if passed else 1

    print(f"replayed={len(fixture_paths)} failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
