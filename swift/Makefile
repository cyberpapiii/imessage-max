# iMessage Max — Build, Sign & Install
#
# Usage:
#   make install       Build, sign, restart service, verify health
#   make build         Build release binary only
#   make test          Run the full test suite
#   make restart       Restart the launchd service
#   make status        Show service health and version
#   make logs          Tail stderr log
#   make clean         Remove debug build artifacts
#   make setup-signing Create persistent code signing identity (one-time)
#
# The signing identity lets Full Disk Access persist across rebuilds.
# Without it, you'd need to re-grant FDA in System Settings every build.
# Run `make setup-signing` once, then `make install` for every update.

BINARY       := .build/release/imessage-max
IDENTITY     := iMessage Max Dev
LAUNCHD_LABEL := local.imessage-max
PORT         := 8080
CERT_CN      := iMessage Max Dev
VERIFY_ATTEMPTS := 45

.PHONY: build test sign install restart status logs clean setup-signing verify help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build release binary
	@echo "Building release..."
	@swift build -c release
	@echo "✓ Built $(BINARY)"

test: ## Run the full test suite
	@swift test

sign: build ## Build and sign with persistent identity
	@if codesign --force --sign "$(IDENTITY)" $(BINARY) 2>/dev/null; then \
		echo "✓ Signed with '$(IDENTITY)' — FDA persists across rebuilds"; \
	elif security find-certificate -c "$(CERT_CN)" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then \
		if codesign --force --sign "$(IDENTITY)" $(BINARY); then \
			echo "✓ Signed with '$(IDENTITY)'"; \
		else \
			echo "✗ Failed to sign with '$(IDENTITY)'"; \
			exit 1; \
		fi; \
	else \
		echo "⚠ No signing identity '$(IDENTITY)' — using ad-hoc (FDA needs re-granting each build)"; \
		echo "  Run 'make setup-signing' once to fix this permanently"; \
		codesign --force --sign - $(BINARY); \
	fi

restart: ## Restart the launchd service
	@echo "Restarting service..."
	@launchctl bootout gui/$$(id -u) ~/Library/LaunchAgents/$(LAUNCHD_LABEL).plist 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) ~/Library/LaunchAgents/$(LAUNCHD_LABEL).plist
	@echo "✓ Service restarted"

verify: ## Verify server is healthy
	@echo "Waiting for server..."
	@BINARY_VERSION=$$($(BINARY) --version 2>/dev/null); \
	i=1; \
	while [ $$i -le $(VERIFY_ATTEMPTS) ]; do \
		sleep 1; \
		RESULT=$$(curl -sf http://127.0.0.1:$(PORT) -X POST \
			-H "Content-Type: application/json" \
			-H "Accept: application/json, text/event-stream" \
			-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}' 2>/dev/null); \
		if [ -n "$$RESULT" ]; then \
			SERVER_VERSION=$$(echo "$$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['serverInfo']['version'])"); \
			if [ "$$SERVER_VERSION" = "$$BINARY_VERSION" ]; then \
				echo "$$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(f'✓ Legacy lane — {r[\"serverInfo\"][\"name\"]} v{r[\"serverInfo\"][\"version\"]} healthy on port $(PORT)')"; \
				MODERN=$$(curl -sf http://127.0.0.1:$(PORT) -X POST \
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
	echo "✗ Server not responding on port $(PORT)"; exit 1

install: sign restart verify ## Build, sign, restart, verify (the full workflow)
	@open -R $(BINARY)
	@echo ""
	@echo "Done! Finder opened to the binary — drag it into Full Disk Access if needed."
	@echo "If MCP Router lost connection, reconnect with /mcp"

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
	@curl -sf http://127.0.0.1:$(PORT) -X POST \
		-H "Content-Type: application/json" \
		-H "Accept: application/json, text/event-stream" \
		-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"status","version":"1.0"}}}' 2>/dev/null \
		| python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(f'✓ Responding — v{r[\"serverInfo\"][\"version\"]}')" 2>/dev/null \
		|| echo "✗ Not responding"

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

# setup-signing runs as a SINGLE shell program (one `\`-continued line) so that
# the private key lives in a `mktemp -d` directory removed by an EXIT trap on
# every path — success, failure, or interrupt. Splitting it back into separate
# `@` lines would give each line its own shell, which is what previously let the
# early "already works" exit fall through into regenerating the cert.
#
# Step notes, in recipe order:
#   - openssl req: generate cert with the code signing EKU
#   - openssl pkcs12: package as PKCS12 (legacy format for Keychain compatibility)
#   - security import: import to the login keychain
#   - security set-key-partition-list: let codesign use the key without prompting
#   - security add-trusted-cert: makes `find-identity -v` report it valid and
#     removes the manual Keychain Access trust step. Pops a login-password
#     dialog (expected). Signing already works without this; trust only affects
#     how the cert is reported, not signability.
setup-signing: ## Create persistent code signing identity (one-time)
	@if codesign --force --sign "$(IDENTITY)" --generate-entitlement-der /dev/null 2>/dev/null; then \
		echo "✓ Signing identity '$(IDENTITY)' already works"; \
		exit 0; \
	fi; \
	SIGNTMP=$$(mktemp -d); \
	trap 'rm -rf "$$SIGNTMP"' EXIT; \
	echo "Creating self-signed code signing certificate '$(CERT_CN)'..."; \
	echo "This lets Full Disk Access persist across rebuilds."; \
	echo ""; \
	openssl req -x509 -newkey rsa:2048 \
		-keyout "$$SIGNTMP/key.pem" -out "$$SIGNTMP/cert.pem" \
		-days 3650 -nodes \
		-subj "/CN=$(CERT_CN)" \
		-addext "keyUsage=critical,digitalSignature" \
		-addext "extendedKeyUsage=critical,codeSigning" \
		2>/dev/null; \
	openssl pkcs12 -export \
		-out "$$SIGNTMP/bundle.p12" \
		-inkey "$$SIGNTMP/key.pem" \
		-in "$$SIGNTMP/cert.pem" \
		-passout pass:_imtmp \
		-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
		2>/dev/null; \
	security import "$$SIGNTMP/bundle.p12" \
		-k ~/Library/Keychains/login.keychain-db \
		-P "_imtmp" \
		-T /usr/bin/codesign; \
	security set-key-partition-list -S apple-tool:,apple:,codesign: \
		-s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true; \
	echo "Trusting the cert for code signing (a login-password dialog is expected)..."; \
	security add-trusted-cert -r trustRoot -p codeSign "$$SIGNTMP/cert.pem" 2>/dev/null || true; \
	echo ""; \
	if codesign --force --sign "$(IDENTITY)" $(BINARY) 2>/dev/null; then \
		echo "✓ Signing identity '$(IDENTITY)' created and working"; \
		echo "  Grant FDA one more time in System Settings — it will persist across rebuilds."; \
	else \
		echo "⚠ Certificate imported but needs manual trust:"; \
		echo "  1. Open Keychain Access"; \
		echo "  2. Find '$(CERT_CN)' in login keychain"; \
		echo "  3. Double-click → Trust → Code Signing → Always Trust"; \
	fi
