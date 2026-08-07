#!/usr/bin/env python3
"""Capture the G0-01 live contract, masked goldens, and error taxonomy."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from mcp_http import DEFAULT_URL, LegacyClient, modern_request


GOLDEN_CALLS = [
    ("list_chats", {"limit": 3}),
    (
        "find_chat",
        {"participants": ["__imessage_max_battle_test_no_match_7f4c__"]},
    ),
    (
        "search",
        {"query": "__imessage_max_battle_test_no_match_7f4c__", "limit": 3},
    ),
    ("get_unread", {"limit": 3}),
    ("diagnose", {}),
]

ERROR_CALLS = [
    (
        "invalid chat_id",
        "get_chat_details",
        {"chat_id": "__battle_invalid_chat_id__"},
    ),
    ("missing chat_id", "get_chat_details", {}),
    ("missing attachment_id", "get_attachment", {}),
]


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256_json(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def mask_value(value: Any, key: str | None = None) -> Any:
    if isinstance(value, dict):
        return {item_key: mask_value(item, item_key) for item_key, item in value.items()}
    if isinstance(value, list):
        masked = [mask_value(item, key) for item in value[:3]]
        if len(value) > 3:
            masked.append({"_masked_remaining_items": len(value) - 3})
        return masked
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)):
        return 0
    if isinstance(value, str):
        if key in {"jsonrpc", "type"}:
            return value
        return "<MASKED>"
    return "<MASKED>"


def mask_tool_response(body: dict[str, Any]) -> dict[str, Any]:
    masked = mask_value(body)
    result = body.get("result")
    masked_result = masked.get("result") if isinstance(masked, dict) else None
    if not isinstance(result, dict) or not isinstance(masked_result, dict):
        return masked

    content = result.get("content")
    masked_content = masked_result.get("content")
    if not isinstance(content, list) or not isinstance(masked_content, list):
        return masked

    for index, item in enumerate(content[: len(masked_content)]):
        if not isinstance(item, dict) or not isinstance(masked_content[index], dict):
            continue
        text = item.get("text")
        if not isinstance(text, str):
            continue
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            masked_content[index]["text"] = "<MASKED_TEXT>"
        else:
            masked_content[index]["text"] = "<MASKED_JSON_TEXT>"
            masked_content[index]["parsedText"] = mask_value(parsed)
    return masked


def tool_call_succeeded(body: dict[str, Any] | None) -> bool:
    if not isinstance(body, dict) or "error" in body:
        return False
    result = body.get("result")
    return isinstance(result, dict) and result.get("isError") is not True


def tool_error_code(body: dict[str, Any] | None) -> str | None:
    if not isinstance(body, dict):
        return None
    result = body.get("result")
    if not isinstance(result, dict):
        return None
    content = result.get("content")
    if not isinstance(content, list) or not content:
        return None
    first = content[0]
    if not isinstance(first, dict) or not isinstance(first.get("text"), str):
        return None
    try:
        parsed = json.loads(first["text"])
    except json.JSONDecodeError:
        return None
    error = parsed.get("error")
    return error if isinstance(error, str) else None


def safe_error_body(body: dict[str, Any] | None) -> Any:
    if body is None:
        return None
    serialized = json.dumps(body, sort_keys=True, indent=2)
    return json.loads(
        serialized.replace("__battle_invalid_chat_id__", "<INVALID_CHAT_ID>")
    )


def write_contract(
    reports_dir: Path,
    legacy_initialize: dict[str, Any],
    legacy_tools_body: dict[str, Any],
    modern_discover_body: dict[str, Any] | None,
    modern_tools_body: dict[str, Any] | None,
) -> None:
    tools = legacy_tools_body["result"]["tools"]
    overall_hash = sha256_json(legacy_tools_body)
    tool_rows = []
    for tool in tools:
        required = ", ".join(tool.get("inputSchema", {}).get("required", [])) or "—"
        schema_hash = sha256_json(tool.get("inputSchema", {}))
        tool_rows.append(
            f"| `{tool['name']}` | `{schema_hash}` | {required} |"
        )

    initialize_result = legacy_initialize.get("result", {})
    discover_result = (
        modern_discover_body.get("result", {})
        if isinstance(modern_discover_body, dict)
        else {}
    )
    modern_tools = (
        modern_tools_body.get("result", {}).get("tools", [])
        if isinstance(modern_tools_body, dict)
        else []
    )
    modern_status = (
        f"HTTP/JSON-RPC success; supported versions "
        f"`{discover_result.get('supportedVersions', [])}`; "
        f"result type `{discover_result.get('resultType', 'unknown')}`."
        if discover_result
        else "Blocked or unavailable; see capture command output."
    )
    modern_parity = (
        f"`tools/list` returned {len(modern_tools)} tools; canonical tool-array "
        f"SHA-256 `{sha256_json(modern_tools)}`; "
        f"legacy/modern arrays equal: `{modern_tools == tools}`."
        if modern_tools
        else "`tools/list` did not return a tool array."
    )

    markdown = f"""# G0-01 Contract Capture

Captured from the live loopback server at `{DEFAULT_URL}`. The legacy lane
negotiated protocol `{initialize_result.get('protocolVersion', 'unknown')}` and
server version `{initialize_result.get('serverInfo', {}).get('version', 'unknown')}`.

## Legacy `tools/list`

Canonicalization: UTF-8 JSON with sorted keys and no insignificant whitespace.
The full JSON-RPC `tools/list` response SHA-256 is:

`{overall_hash}`

Tool count: **{len(tools)}**

| Tool | Input-schema SHA-256 | Required arguments |
|---|---|---|
{chr(10).join(tool_rows)}

## Modern discover path

`server/discover`: {modern_status}

Modern {modern_parity}

## Scope note

This is observation only. No tool schema or product behavior was changed, and
the `send` tool was listed but never called.
"""
    (reports_dir / "G0-01-contract.md").write_text(markdown, encoding="utf-8")


def write_goldens(reports_dir: Path, client: LegacyClient) -> None:
    golden_dir = reports_dir / "G0-01-goldens"
    golden_dir.mkdir(parents=True, exist_ok=True)
    manifest = []

    for index, (tool_name, arguments) in enumerate(GOLDEN_CALLS, start=1):
        result = client.call_tool(tool_name, arguments)
        if result.body is None:
            raise RuntimeError(f"{tool_name} returned an empty body")
        is_error = not tool_call_succeeded(result.body)
        fixture = {
            "name": tool_name,
            "request": {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments},
            },
            "expected": {
                "http_status": result.status,
                "is_error": is_error,
                "error_code": tool_error_code(result.body),
            },
            "response_masking": (
                "All response strings and numeric values are masked; arrays are "
                "limited to three entries. JSON text content is parsed and masked."
            ),
            "masked_response": mask_tool_response(result.body),
        }
        fixture_path = golden_dir / f"{index:02d}-{tool_name}.json"
        fixture_path.write_text(
            json.dumps(fixture, sort_keys=True, indent=2) + "\n",
            encoding="utf-8",
        )
        manifest.append(
            {
                "fixture": fixture_path.name,
                "captured_success": tool_call_succeeded(result.body),
                "http_status": result.status,
            }
        )

    (golden_dir / "manifest.json").write_text(
        json.dumps(manifest, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )


def write_errors(reports_dir: Path, client: LegacyClient) -> None:
    sections = []
    for label, tool_name, arguments in ERROR_CALLS:
        result = client.call_tool(tool_name, arguments)
        safe_body = safe_error_body(result.body)
        observed_error = tool_error_code(result.body)
        if observed_error == "permission_denied":
            root_class = "permission gate (requested lookup was not reached)"
        elif observed_error == "validation_error":
            root_class = "input-schema validation"
        else:
            root_class = "unclassified observed tool error"
        sections.append(
            f"""## {label}

- Repro: `tools/call` → `{tool_name}` with arguments `{json.dumps(arguments).replace('__battle_invalid_chat_id__', '<INVALID_CHAT_ID>')}`
- HTTP status: `{result.status}`
- Tool error code: `{observed_error or 'none'}`
- Root-cause class: {root_class}
- Impact rank: low (deliberate invalid read-path input)
- Observed JSON shape:

```json
{json.dumps(safe_body, sort_keys=True, indent=2)}
```
"""
        )

    markdown = """# G0-01 Observed Error Taxonomy

These are live observations from deliberate bad inputs. They are taxonomy
evidence only; no product fix is proposed or authorized.

""" + "\n".join(sections)
    (reports_dir / "G0-01-errors.md").write_text(markdown, encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reports-dir", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.reports_dir.mkdir(parents=True, exist_ok=True)

    client = LegacyClient()
    legacy_initialize = client.initialize()
    legacy_tools = client.request("tools/list", {})
    if legacy_tools.status != 200 or legacy_tools.body is None:
        raise RuntimeError(f"legacy tools/list failed: {legacy_tools}")

    modern_discover = modern_request("server/discover")
    modern_tools = modern_request("tools/list")
    write_contract(
        args.reports_dir,
        legacy_initialize,
        legacy_tools.body,
        modern_discover.body,
        modern_tools.body,
    )
    write_goldens(args.reports_dir, client)
    write_errors(args.reports_dir, client)
    print(f"wrote G0-01 artifacts under {args.reports_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
