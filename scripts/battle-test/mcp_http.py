#!/usr/bin/env python3
"""Small dependency-free HTTP client for the local iMessage Max MCP server."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


DEFAULT_URL = "http://127.0.0.1:8080"
LEGACY_VERSION = "2025-11-25"
MODERN_VERSION = "2026-07-28"


@dataclass
class HTTPResult:
    status: int
    headers: dict[str, str]
    body: dict[str, Any] | None


def post_json(
    url: str,
    payload: dict[str, Any],
    headers: dict[str, str] | None = None,
    timeout: float = 30.0,
) -> HTTPResult:
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request_headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    request_headers.update(headers or {})
    request = urllib.request.Request(
        url,
        data=encoded,
        headers=request_headers,
        method="POST",
    )

    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        raw = error.read()
        body = json.loads(raw) if raw else None
        return HTTPResult(error.code, dict(error.headers.items()), body)

    with response:
        raw = response.read()
        body = json.loads(raw) if raw else None
        return HTTPResult(response.status, dict(response.headers.items()), body)


class LegacyClient:
    def __init__(self, url: str = DEFAULT_URL) -> None:
        self.url = url
        self.session_id: str | None = None
        self.next_id = 1

    def initialize(self) -> dict[str, Any]:
        result = post_json(
            self.url,
            {
                "jsonrpc": "2.0",
                "id": self.next_id,
                "method": "initialize",
                "params": {
                    "protocolVersion": LEGACY_VERSION,
                    "capabilities": {},
                    "clientInfo": {
                        "name": "imessage-max-battle-test",
                        "version": "1.0",
                    },
                },
            },
        )
        self.next_id += 1
        if result.status != 200 or result.body is None:
            raise RuntimeError(f"initialize failed: HTTP {result.status} {result.body}")

        self.session_id = next(
            (
                value
                for key, value in result.headers.items()
                if key.lower() == "mcp-session-id"
            ),
            None,
        )
        if not self.session_id:
            raise RuntimeError("initialize response omitted Mcp-Session-Id")
        return result.body

    def request(self, method: str, params: dict[str, Any]) -> HTTPResult:
        if self.session_id is None:
            self.initialize()
        result = post_json(
            self.url,
            {
                "jsonrpc": "2.0",
                "id": self.next_id,
                "method": method,
                "params": params,
            },
            headers={
                "Mcp-Session-Id": self.session_id or "",
                "MCP-Protocol-Version": LEGACY_VERSION,
            },
        )
        self.next_id += 1
        return result

    def call_tool(self, name: str, arguments: dict[str, Any]) -> HTTPResult:
        return self.request(
            "tools/call",
            {"name": name, "arguments": arguments},
        )


def modern_request(
    method: str,
    params: dict[str, Any] | None = None,
    url: str = DEFAULT_URL,
) -> HTTPResult:
    modern_params = dict(params or {})
    modern_params["_meta"] = {
        "io.modelcontextprotocol/protocolVersion": MODERN_VERSION,
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": {
            "name": "imessage-max-battle-test",
            "version": "1.0",
        },
    }
    return post_json(
        url,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": modern_params,
        },
        headers={
            "MCP-Protocol-Version": MODERN_VERSION,
            "Mcp-Method": method,
        },
    )
