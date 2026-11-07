# iMessage Max: build, sign, install
#
# Usage:
#   make install       Build, sign, restart service, verify health
#   make build         Build release binary only
#   make test          Run the full test suite (FILTER=ClassOrMethod for a subset)
#   make restart       Restart the launchd service
#   make install-agent Install the launchd plist from swift/launchd/
#   make status        Show service health and version
#   make logs          Tail stderr log
#   make clean         Remove debug build artifacts
#   make version       Print the version and check all copies agree
#   make release-check Everything that must pass before tagging a release
#
# `sign` uses SIGN_IDENTITY (a certificate SHA-1) or else the Developer ID
# Application identity in the keychain that expires last, so Full Disk Access
# persists across rebuilds. With neither it signs ad hoc, and FDA must be
# granted again after every build.

BINARY       := .build/release/imessage-max
LAUNCHD_LABEL := local.imessage-max
PLIST        := $(HOME)/Library/LaunchAgents/$(LAUNCHD_LABEL).plist
# The port the installed agent listens on (`--port N` or `--port=N` in its
# ProgramArguments), so verify and status probe the service that is running.
# Falls back to the template's 8080. Override with `make status PORT=9191`.
PORT         := $(or $(shell [ -f "$(PLIST)" ] && plutil -extract ProgramArguments json -o - "$(PLIST)" 2>/dev/null | \
	tr -d '[]"' | tr ',' '\n' | awk 'take { print; exit } $$0 == "--port" { take = 1 } sub(/^--port=/, "") { print; exit }'),8080)
URL          := http://127.0.0.1:$(PORT)
# The probes send the service's bearer token. Override for a server started
# with --token-file, as in `make verify-db PORT=18484 TOKEN_FILE=/tmp/token`.
TOKEN_FILE   := $(HOME)/Library/Application Support/iMessage Max/token
AUTH_HEADER   = -H "Authorization: Bearer $$(cat "$(TOKEN_FILE)" 2>/dev/null)"
VERIFY_ATTEMPTS := 45
# Per-probe cap, so a server that accepts but never answers fails the probe
# instead of hanging make.
CURL_MAX_TIME := 5
INFO_PLIST   := $(CURDIR)/Sources/Resources/Info.plist
# The legacy (session-based) MCP lane the probes speak.
MCP_LEGACY_VERSION := 2025-11-25

# $(call mcp_initialize,<clientInfo name>,<extra curl short flags>): POST a
# legacy initialize to the service and print the reply.
mcp_initialize = curl -s$(2) --max-time $(CURL_MAX_TIME) "$(URL)" -X POST $(AUTH_HEADER) \
	-H "Content-Type: application/json" \
	-H "Accept: application/json, text/event-stream" \
	-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"$(MCP_LEGACY_VERSION)","capabilities":{},"clientInfo":{"name":"$(1)","version":"1.0"}}}' 2>/dev/null
# token_refused succeeds when the service answers 401, so a probe can name
# the token instead of reporting the service as down.
token_refused = [ "$$(curl -s -o /dev/null -w '%{http_code}' --max-time $(CURL_MAX_TIME) "$(URL)" -X POST $(AUTH_HEADER))" = 401 ]
token_refused_message = ✗ The service refused the token in $(TOKEN_FILE)
# $(call server_info,<field>): read result.serverInfo.<field> from an
# initialize reply on stdin.
server_info = python3 -c "import sys,json; print(json.load(sys.stdin)['result']['serverInfo']['$(1)'])"

.PHONY: build test sign install restart status logs clean verify verify-db help version release-check install-agent

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build release binary
	@echo "Building release..."
	@# Swift 6.4's default build system writes to .build/out/Products/Release.
	@# Full Disk Access is bound to the executable's path, and the existing
	@# grant names .build/arm64-apple-macosx/release, so keep the native layout.
	@# The embedded Info.plist is what lets macOS grant Contacts to the binary.
	@swift build -c release --build-system native \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$(INFO_PLIST)"
	@echo "✓ Built $(BINARY)"

test: ## Run the full test suite (FILTER=ClassOrMethod to run a subset)
	@swift test $(if $(FILTER),--filter $(FILTER),)

version: ## Print the version and check all copies agree
	@../scripts/check-version.sh

release-check: build test version ## Everything that must pass before tagging
	@../scripts/check-version.sh --tag || echo "Not on a matching tag yet (expected before tagging)."
	@ruby -c Formula/imessage-max.rb
	@echo "Release checks passed. Next: git tag v$$(../scripts/check-version.sh --print) && git push --tags"

sign: build ## Build and sign with the Developer ID, else ad hoc
	@SIGN_IDENTITY="$(SIGN_IDENTITY)" ../script/sign.sh $(BINARY) --entitlements iMessageMax.entitlements \
		--identifier "$$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(INFO_PLIST)")"

restart: ## Restart the launchd service
	@echo "Restarting service..."
	@test -f $(PLIST) || (echo "Install the launch agent first: make install-agent" && exit 1)
	@launchctl bootout gui/$$(id -u) $(PLIST) 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) $(PLIST)
	@echo "✓ Service restarted"

# launchd does not expand ~, so the log paths get $(HOME) here, as the
# companion's ServiceConfiguration.renderTemplate does. A loaded agent is
# booted out first: bootstrap refuses a label that is already loaded.
install-agent: ## Install the launchd plist from swift/launchd/
	@if launchctl print gui/$$(id -u)/$(LAUNCHD_LABEL) >/dev/null 2>&1; then \
		launchctl bootout gui/$$(id -u)/$(LAUNCHD_LABEL); \
	fi
	@sed -e "s|__BIN__|$(shell pwd)/.build/release/imessage-max|" -e "s|~/|$(HOME)/|g" \
		launchd/local.imessage-max.plist > $(PLIST)
	@launchctl bootstrap gui/$$(id -u) $(PLIST)
	@echo "✓ Installed $(PLIST)"

verify: ## Verify server is healthy
	@echo "Waiting for server..."
	@BINARY_VERSION=$$($(BINARY) --version 2>/dev/null | grep -o '[0-9.]*$$'); \
	i=1; \
	LAST_BODY=""; \
	CURL_OK=0; \
	while [ $$i -le $(VERIFY_ATTEMPTS) ]; do \
		[ $$i -gt 1 ] && sleep 1; \
		CURL_STATUS=0; \
		RESULT=$$($(call mcp_initialize,verify,f)) || CURL_STATUS=$$?; \
		if [ $$CURL_STATUS -ne 0 ] && $(token_refused); then echo "$(token_refused_message)"; exit 1; fi; \
		if [ $$CURL_STATUS -eq 0 ]; then \
			CURL_OK=1; \
			LAST_BODY=$$RESULT; \
			SERVER_VERSION=""; \
			if command -v python3 >/dev/null 2>&1; then \
				SERVER_VERSION=$$(echo "$$RESULT" | $(call server_info,version) 2>/dev/null) || SERVER_VERSION=""; \
			elif echo "$$RESULT" | grep -q '"result"'; then \
				SERVER_VERSION=$$BINARY_VERSION; \
			fi; \
			if [ -n "$$SERVER_VERSION" ] && [ "$$SERVER_VERSION" = "$$BINARY_VERSION" ]; then \
				if command -v python3 >/dev/null 2>&1; then \
					echo "✓ Legacy lane: $$(echo "$$RESULT" | $(call server_info,name)) v$$SERVER_VERSION healthy on port $(PORT)"; \
				else \
					echo "✓ Legacy lane: v$$SERVER_VERSION healthy on port $(PORT)"; \
				fi; \
				MODERN=$$(curl -sf --max-time $(CURL_MAX_TIME) "$(URL)" -X POST $(AUTH_HEADER) \
					-H "Content-Type: application/json" \
					-H "Accept: application/json, text/event-stream" \
					-H "MCP-Protocol-Version: 2026-07-28" \
					-H "Mcp-Method: server/discover" \
					-d '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' 2>/dev/null); \
				if echo "$$MODERN" | grep -q 'serverInfo'; then \
					echo "✓ Modern lane (2026-07-28) healthy"; \
					exit 0; \
				else \
					echo "✗ Legacy lane OK but modern server/discover failed"; \
					exit 1; \
				fi; \
			fi; \
		fi; \
		i=$$((i + 1)); \
	done; \
	if [ $$CURL_OK -eq 0 ]; then \
		echo "✗ Server not responding on $(URL)"; \
		exit 1; \
	fi; \
	printf '%s' "$$LAST_BODY" | head -c 200; echo; \
	echo "✗ Unexpected response (not JSON)"; \
	exit 1

verify-db: ## Call diagnose over HTTP and fail if the service cannot read chat.db
	@INIT=$$($(call mcp_initialize,verify-db,i)) \
		|| { echo "✗ Server not responding on $(URL)"; exit 1; }; \
	SESSION=$$(printf '%s' "$$INIT" | tr -d '\r' | awk 'tolower($$1)=="mcp-session-id:" {print $$2}'); \
	if [ -z "$$SESSION" ]; then \
		if $(token_refused); then echo "$(token_refused_message)"; else echo "✗ initialize returned no Mcp-Session-Id header"; fi; \
		exit 1; \
	fi; \
	BODY=$$(curl -sf --max-time 15 "$(URL)" -X POST $(AUTH_HEADER) \
		-H "Content-Type: application/json" \
		-H "Accept: application/json, text/event-stream" \
		-H "Mcp-Session-Id: $$SESSION" \
		-H "MCP-Protocol-Version: $(MCP_LEGACY_VERSION)" \
		-d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnose","arguments":{}}}' 2>/dev/null) \
		|| { echo "✗ tools/call diagnose failed"; exit 1; }; \
	curl -s --max-time 2 -o /dev/null "$(URL)" -X DELETE $(AUTH_HEADER) -H "Mcp-Session-Id: $$SESSION" -H "MCP-Protocol-Version: $(MCP_LEGACY_VERSION)" || true; \
	printf '%s' "$$BODY" | python3 -c '\
import sys, json; \
r = json.load(sys.stdin)["result"]; \
db = r["structuredContent"]["database"]; \
ok = db.get("accessible") is True; \
print(("✓ Database accessible: " if ok else "✗ Database NOT accessible: ") + db.get("status", "?") + " (" + db.get("path", "?") + ", pid " + str(r["structuredContent"].get("process_id")) + ")"); \
fix = db.get("fix"); \
print("  " + fix) if (not ok and fix) else None; \
sys.exit(0 if ok else 1)' \
	|| { echo "  Run: open -R $(BINARY)   # then drag it into Full Disk Access, then make restart"; exit 1; }

install: sign restart verify verify-db ## Build, sign, restart, verify (the full workflow)
	@echo "Done. Database access verified."

status: ## Show service status and version
	@echo "=== Process ==="
	@pgrep -fl "imessage-max.*$(PORT)" || echo "Not running"
	@echo ""
	@echo "=== Version ==="
	@$(BINARY) --version 2>/dev/null || echo "Binary not found"
	@echo ""
	@echo "=== Signature ==="
	@codesign -dvv $(BINARY) 2>&1 | grep -E "Signature|Authority|CDHash" || echo "Not signed"
	@echo ""
	@echo "=== Health ==="
	@BODY=$$($(call mcp_initialize,status,f)) || { \
		if $(token_refused); then echo "$(token_refused_message)"; else echo "✗ Not responding"; fi; exit 0; }; \
	if command -v python3 >/dev/null 2>&1; then \
		VERSION=$$(echo "$$BODY" | $(call server_info,version) 2>/dev/null) && echo "✓ Responding, v$$VERSION" \
			|| { printf '%s' "$$BODY" | head -c 200; echo; echo "✗ Unexpected response (not JSON)"; }; \
	elif echo "$$BODY" | grep -q '"result"'; then \
		echo "✓ Responding"; \
	else \
		printf '%s' "$$BODY" | head -c 200; echo; \
		echo "✗ Unexpected response (not JSON)"; \
	fi

logs: ## Tail the stderr log
	@tail -f ~/Library/Logs/imessage-max.stderr.log

clean: ## Remove debug artifacts and old logs
	@echo "Cleaning..."
	@rm -rf .build/debug .build/arm64-apple-macosx/debug .build/debug.yaml
	@echo "  Removed debug build artifacts"
	@cat /dev/null > ~/Library/Logs/imessage-max.stderr.log 2>/dev/null || true
	@cat /dev/null > ~/Library/Logs/imessage-max.stdout.log 2>/dev/null || true
	@echo "  Cleared log files"
	@echo "✓ Clean"
