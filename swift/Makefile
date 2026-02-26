# iMessage Max — Build, Sign & Install
#
# Usage:
#   make install       Build, sign, restart service, verify health
#   make build         Build release binary only
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

.PHONY: build sign install restart status logs clean setup-signing verify help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build release binary
	@echo "Building release..."
	@swift build -c release 2>&1 | grep -E "Build complete|error:|warning:.*imessage" || true
	@echo "✓ Built $(BINARY)"

sign: build ## Build and sign with persistent identity
	@if codesign --force --sign "$(IDENTITY)" $(BINARY) 2>/dev/null; then \
		echo "✓ Signed with '$(IDENTITY)' — FDA persists across rebuilds"; \
	elif security find-certificate -c "$(CERT_CN)" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then \
		codesign --force --sign "$(IDENTITY)" $(BINARY) 2>&1; \
		echo "✓ Signed with '$(IDENTITY)'"; \
	else \
		echo "⚠ No signing identity '$(IDENTITY)' — using ad-hoc (FDA needs re-granting each build)"; \
		echo "  Run 'make setup-signing' once to fix this permanently"; \
	fi

restart: ## Restart the launchd service
	@echo "Restarting service..."
	@launchctl kickstart -k gui/$$(id -u)/$(LAUNCHD_LABEL) 2>/dev/null || \
		(launchctl bootstrap gui/$$(id -u) ~/Library/LaunchAgents/$(LAUNCHD_LABEL).plist 2>/dev/null && echo "Bootstrapped") || true
	@echo "✓ Service restarted"

verify: ## Verify server is healthy
	@echo "Waiting for server..."
	@for i in 1 2 3 4 5 6 7 8; do \
		sleep 1; \
		RESULT=$$(curl -sf http://127.0.0.1:$(PORT) -X POST \
			-H "Content-Type: application/json" \
			-H "Accept: application/json" \
			-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}' 2>/dev/null); \
		if [ -n "$$RESULT" ]; then \
			echo "$$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(f'✓ {r[\"serverInfo\"][\"name\"]} v{r[\"serverInfo\"][\"version\"]} healthy on port $(PORT)')"; \
			exit 0; \
		fi; \
	done; \
	echo "✗ Server not responding on port $(PORT)"; exit 1

install: sign restart verify ## Build, sign, restart, verify (the full workflow)
	@echo ""
	@echo "Done! If MCP Router lost connection, reconnect with /mcp"

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
		-H "Accept: application/json" \
		-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"status","version":"1.0"}}}' 2>/dev/null \
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

setup-signing: ## Create persistent code signing identity (one-time)
	@if codesign --force --sign "$(IDENTITY)" --generate-entitlement-der /dev/null 2>/dev/null; then \
		echo "✓ Signing identity '$(IDENTITY)' already works"; \
		exit 0; \
	fi
	@echo "Creating self-signed code signing certificate '$(CERT_CN)'..."
	@echo "This lets Full Disk Access persist across rebuilds."
	@echo ""
	@# Generate cert with code signing EKU
	openssl req -x509 -newkey rsa:2048 \
		-keyout /tmp/_im_key.pem -out /tmp/_im_cert.pem \
		-days 3650 -nodes \
		-subj "/CN=$(CERT_CN)" \
		-addext "extendedKeyUsage=codeSigning" \
		-addext "keyUsage=digitalSignature" \
		2>/dev/null
	@# Package as PKCS12 (legacy format for macOS Keychain compatibility)
	openssl pkcs12 -export \
		-out /tmp/_im.p12 \
		-inkey /tmp/_im_key.pem \
		-in /tmp/_im_cert.pem \
		-passout pass:_imtmp \
		-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
		2>/dev/null
	@# Import to login keychain
	security import /tmp/_im.p12 \
		-k ~/Library/Keychains/login.keychain-db \
		-P "_imtmp" \
		-T /usr/bin/codesign
	@# Allow codesign to access the key without prompting
	security set-key-partition-list -S apple-tool:,apple:,codesign: \
		-s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
	@# Clean up temp files
	@rm -f /tmp/_im_key.pem /tmp/_im_cert.pem /tmp/_im.p12
	@echo ""
	@# Verify it works
	@if codesign --force --sign "$(IDENTITY)" $(BINARY) 2>/dev/null; then \
		echo "✓ Signing identity '$(IDENTITY)' created and working"; \
		echo "  Grant FDA one more time in System Settings — it will persist across rebuilds."; \
	else \
		echo "⚠ Certificate imported but needs manual trust:"; \
		echo "  1. Open Keychain Access"; \
		echo "  2. Find '$(CERT_CN)' in login keychain"; \
		echo "  3. Double-click → Trust → Code Signing → Always Trust"; \
	fi
