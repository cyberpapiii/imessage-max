# Battle-test levers

These local, dependency-free commands exercise the loopback MCP server without
changing product behavior. Start from the repository root with the signed
launchd service healthy (`make -C swift status`). Read-path calls are the
default; none of these commands calls `send`.

```bash
# Repeatable latency, error-count, and RSS sample for hot read tools
scripts/battle-test/baseline.sh

# Compare all 12 live per-tool input schemas with the committed SHA-256 pins
python3 scripts/battle-test/check_schemas.py

# Replay masked read-path fixtures captured by G0-01
python3 scripts/battle-test/replay_goldens.py \
  --fixtures-dir /path/to/reports/G0-01-goldens

# Refresh contract, masked goldens, and observed error taxonomy
python3 scripts/battle-test/capture.py \
  --reports-dir /path/to/reports
```

`check_schemas.py` exits non-zero for a missing, unexpected, or changed tool
schema. Schema pin updates are intentional review events: fetch live
`tools/list`, inspect the schema change, then update `schema-hashes.json`.
