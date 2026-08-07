#!/usr/bin/env python3
"""Print a small repeatable latency/error/RSS baseline for hot read tools."""

from __future__ import annotations

import math
import os
import re
import statistics
import subprocess
import time
from pathlib import Path
from typing import Any

from mcp_http import LegacyClient


HOT_CALLS = [
    ("list_chats", {"limit": 5}),
    (
        "search",
        {"query": "__imessage_max_battle_test_no_match_7f4c__", "limit": 5},
    ),
    ("diagnose", {}),
]


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def response_is_error(status: int, body: dict[str, Any] | None) -> bool:
    if status != 200 or not isinstance(body, dict) or "error" in body:
        return True
    result = body.get("result")
    return not isinstance(result, dict) or result.get("isError") is True


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    status = subprocess.run(
        ["make", "-C", str(repo_root / "swift"), "status"],
        capture_output=True,
        text=True,
        check=False,
    )
    if status.returncode != 0 or "✓ Responding" not in status.stdout:
        print("server unhealthy")
        print(status.stdout, end="")
        print(status.stderr, end="")
        return 1

    pid_match = re.search(
        r"(?m)^(\d+)\s+.*imessage-max\s+--http\s+--port\s+8080",
        status.stdout,
    )
    if pid_match is None:
        print("server unhealthy: unable to identify launchd process")
        return 1
    pid = pid_match.group(1)

    samples = int(os.environ.get("BATTLE_SAMPLES", "10"))
    if samples < 1:
        print("BATTLE_SAMPLES must be at least 1")
        return 2

    client = LegacyClient()
    try:
        client.initialize()
    except Exception as error:
        print(f"server unhealthy: initialize failed: {error}")
        return 1

    rows = []
    total_errors = 0
    for tool_name, arguments in HOT_CALLS:
        latencies = []
        errors = 0
        for _ in range(samples):
            started = time.perf_counter()
            result = client.call_tool(tool_name, arguments)
            latencies.append((time.perf_counter() - started) * 1000)
            errors += int(response_is_error(result.status, result.body))
        total_errors += errors
        rows.append(
            (
                tool_name,
                samples,
                statistics.median(latencies),
                percentile(latencies, 0.95),
                errors,
            )
        )

    rss = subprocess.run(
        ["ps", "-o", "rss=", "-p", pid],
        capture_output=True,
        text=True,
        check=False,
    )
    rss_kib = rss.stdout.strip() if rss.returncode == 0 else "unavailable"

    print("| tool | samples | p50_ms | p95_ms | errors |")
    print("|---|---:|---:|---:|---:|")
    for tool_name, count, p50, p95, errors in rows:
        print(f"| {tool_name} | {count} | {p50:.2f} | {p95:.2f} | {errors} |")
    print(f"\nserver_pid={pid} rss_kib={rss_kib} total_errors={total_errors}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
