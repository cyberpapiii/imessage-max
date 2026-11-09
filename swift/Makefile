# iMessage Max: build, sign, install
#
# Usage:
#   make install       Build the app, install it over the released copy in /Applications
#                      or else to ~/Applications, register the helper, verify
#   make build         Build release binary only
#   make test          Run the full test suite (FILTER=ClassOrMethod for a subset)
#   make restart       Restart the helper
#   make status        Show service health and version
#   make logs          Tail the helper log
#   make clean         Remove debug build artifacts
#   make version       Print the version and check all copies agree
#   make release-check Everything that must pass before tagging a release
#
# `sign` uses SIGN_IDENTITY (a certificate SHA-1) or else the Developer ID
# Application identity in the keychain that expires last, so Full Disk Access
# persists across rebuilds. With neither it signs ad hoc, and FDA must be
# granted again after every build.

BINARY       := .build/release/imessage-max
LAUNCHD_LABEL := com.cyberpapiii.imessage-max.helper
AGENT_PLIST  := ../macos/Resources/LaunchAgents/$(LAUNCHD_LABEL).plist
APP_NAME     := iMessage Max
APP_BUILD    := ../dist/$(APP_NAME).app
# The app installs over a released copy in /Applications, where the DMG and
# the cask put it, so the Mac never holds two bundles that register the same
# helper label. With no copy there it goes to ~/Applications. The helper runs
# from inside it. These paths hold spaces, so recipes quote them.
APP_DIR      := $(shell [ -d "/Applications/$(APP_NAME).app" ] && echo /Applications || echo "$(HOME)/Applications")
APP          := $(APP_DIR)/$(APP_NAME).app
LOG          := $(HOME)/Library/Logs/iMessage Max/imessage-max.log
# The port in the agent plist's ProgramArguments (`--port N` or `--port=N`),
# so verify and status probe the helper that is running. Falls back to the
# default 47821. Override with `make status PORT=9191`.
PORT         := $(or $(shell plutil -extract ProgramArguments json -o - "$(AGENT_PLIST)" 2>/dev/null | \
	tr -d '[]"' | tr ',' '\n' | awk 'take { print; exit } $$0 == "--port" { take = 1 } sub(/^--port=/, "") { print; exit }'),47821)
URL          := http://127.0.0.1:$(PORT)
# The probes send the service's bearer token. Override for a server started
# with --token-file, as in `make verify-db PORT=18484 TOKEN_FILE=/tmp/token`.
TOKEN_FILE   := $(HOME)/Library/Application Support/iMessage Max/token
# curl reads the header from stdin (-K -), because other users can read a
# process's arguments with ps. printf is a shell builtin, so it adds none.
AUTH_CURL     = printf 'header = "Authorization: Bearer %s"\n' "$$(cat "$(TOKEN_FILE)" 2>/dev/null)" | curl -K -
VERIFY_ATTEMPTS := 45
# The pid launchd runs the helper as now, empty when none.
helper_pid = launchctl print gui/$$(id -u)/$(LAUNCHD_LABEL) 2>/dev/null | awk '$$1 == "pid" && $$2 == "=" { print $$3; exit }'
# Seconds install waits for a helper other than the one it replaced. A
# restart can wait out the plist's 10 second ThrottleInterval, and the
# companion's own wait for the helper is about 18 seconds.
HELPER_WAIT  := 45
# $(call wait_new_helper,<old pid>): wait until launchd runs the helper as
# another pid, and fail when it does not. The old helper still answers, so
# verify would pass against the old binary.
wait_new_helper = echo "Waiting for the new helper..."; i=0; PID=""; \
	while [ $$i -lt $(HELPER_WAIT) ]; do \
		PID=$$($(helper_pid)); \
		if [ -n "$$PID" ] && [ "$$PID" != "$(1)" ]; then echo "✓ Helper running as pid $$PID"; break; fi; \
		sleep 1; i=$$((i + 1)); \
	done; \
	[ $$i -lt $(HELPER_WAIT) ] || { \
		if [ -n "$$PID" ]; then \
			echo "✗ No new helper after $(HELPER_WAIT) s. launchd still runs pid $$PID, the helper from before the install, on the old binary."; \
		else \
			echo "✗ No helper running after $(HELPER_WAIT) s. Check that iMessage Max is on in System Settings → General → Login Items & Extensions."; \
		fi; \
		echo "  Run: open -n \"$(APP)\" --args --register-helper, then make verify"; \
		exit 1; }
# The installed companion's executable, which pkill and pgrep match.
COMPANION    = $(APP)/Contents/MacOS/iMessageMaxMenu
# Seconds install waits for the companion it opened before it opens it again.
COMPANION_WAIT := 10
# open_companion: open the installed app with --register-helper and wait for
# its companion, opening it once more if none starts. -n matters: for a moment
# after the old companion dies, LaunchServices still lists it, and a plain
# open sends that dead instance a reopen event (error -600) and launches
# nothing, so --register-helper never runs (2026-11-09).
open_companion = try=1; while :; do \
		open -n "$(APP)" --args --register-helper || echo "✗ open exited $$? for $(APP)"; \
		i=0; while ! pgrep -f "$(COMPANION)" >/dev/null && [ $$i -lt $$((5 * $(COMPANION_WAIT))) ]; do sleep 0.2; i=$$((i + 1)); done; \
		if pgrep -f "$(COMPANION)" >/dev/null; then echo "✓ Companion running as pid $$(pgrep -f "$(COMPANION)" | paste -sd ' ' -)"; break; fi; \
		if [ $$try -ge 2 ]; then \
			echo "✗ iMessage Max did not start after two tries, so --register-helper never ran."; \
			echo "  Run: open -n \"$(APP)\" --args --register-helper, then make verify"; \
			exit 1; \
		fi; \
		echo "✗ iMessage Max did not start within $(COMPANION_WAIT) s. Opening it again."; \
		try=2; \
	done
# Per-probe cap, so a server that accepts but never answers fails the probe
# instead of hanging make.
CURL_MAX_TIME := 5
INFO_PLIST   := $(CURDIR)/Sources/Resources/Info.plist
# The legacy (session-based) MCP lane the probes speak.
MCP_LEGACY_VERSION := 2025-11-25

# $(call mcp_initialize,<clientInfo name>,<extra curl short flags>): POST a
# legacy initialize to the service and print the reply.
mcp_initialize = $(AUTH_CURL) -s$(2) --max-time $(CURL_MAX_TIME) "$(URL)" -X POST \
	-H "Content-Type: application/json" \
	-H "Accept: application/json, text/event-stream" \
	-d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"$(MCP_LEGACY_VERSION)","capabilities":{},"clientInfo":{"name":"$(1)","version":"1.0"}}}' 2>/dev/null
# token_refused succeeds when the service answers 401, so a probe can name
# the token instead of reporting the service as down.
token_refused = [ "$$($(AUTH_CURL) -s -o /dev/null -w '%{http_code}' --max-time $(CURL_MAX_TIME) "$(URL)" -X POST)" = 401 ]
token_refused_message = ✗ The service refused the token in $(TOKEN_FILE)
# require_server sets LISTENER to the command name of each process listening
# on $(PORT), empty when none, and exits when one is not imessage-max, so the
# probes never hand the token to another program. +c 0 stops lsof cutting
# the name to 9 characters.
require_server = LISTENER=$$(lsof -nP +c 0 -iTCP:$(PORT) -sTCP:LISTEN -Fc 2>/dev/null | sed -n 's/^c//p' | sort -u | paste -sd ' ' -); \
	if [ -n "$$LISTENER" ] && [ "$$LISTENER" != imessage-max ]; then \
		echo "✗ Port $(PORT) is held by $$LISTENER, not imessage-max. The token was not sent."; exit 1; \
	fi
# $(call server_info,<field>): read result.serverInfo.<field> from an
# initialize reply on stdin.
server_info = python3 -c "import sys,json; print(json.load(sys.stdin)['result']['serverInfo']['$(1)'])"

.PHONY: build test sign app install wait-helper restart status logs clean verify verify-db help version release-check

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
	@# The SIGTERM abort (#27) only happened in optimized builds.
	@IMESSAGE_MAX_BINARY=$(BINARY) swift test --skip-build --filter SignalShutdownTests
	@../scripts/check-version.sh --tag || echo "Not on a matching tag yet (expected before tagging)."
	@echo "Release checks passed. Next: git tag v$$(../scripts/check-version.sh --print) && git push --tags"

sign: build ## Build and sign with the Developer ID, else ad hoc
	@SIGN_IDENTITY="$(SIGN_IDENTITY)" ../script/sign.sh $(BINARY) --entitlements iMessageMax.entitlements \
		--identifier "$$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(INFO_PLIST)")"

app: ## Build and sign the app with the helper inside it, into ../dist
	@../script/assemble_app.sh "$(APP_BUILD)" release

restart: ## Restart the helper
	@echo "Restarting service..."
	@launchctl kickstart -k gui/$$(id -u)/$(LAUNCHD_LABEL) \
		|| { echo "The helper is not loaded. Start it from the iMessage Max menu, or run: make install"; exit 1; }
	@echo "✓ Service restarted"

verify: ## Verify server is healthy
	@echo "Waiting for server..."
	@BINARY_VERSION=$$($(BINARY) --version 2>/dev/null | grep -o '[0-9.]*$$'); \
	i=1; \
	LAST_BODY=""; \
	CURL_OK=0; \
	while [ $$i -le $(VERIFY_ATTEMPTS) ]; do \
		[ $$i -gt 1 ] && sleep 1; \
		$(require_server); \
		CURL_STATUS=7; \
		if [ -n "$$LISTENER" ]; then \
			CURL_STATUS=0; \
			RESULT=$$($(call mcp_initialize,verify,f)) || CURL_STATUS=$$?; \
			if [ $$CURL_STATUS -ne 0 ] && $(token_refused); then echo "$(token_refused_message)"; exit 1; fi; \
		fi; \
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
				MODERN=$$($(AUTH_CURL) -sf --max-time $(CURL_MAX_TIME) "$(URL)" -X POST \
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
	@$(require_server); \
	[ -n "$$LISTENER" ] || { echo "✗ Server not responding on $(URL)"; exit 1; }; \
	INIT=$$($(call mcp_initialize,verify-db,i)) \
		|| { echo "✗ Server not responding on $(URL)"; exit 1; }; \
	SESSION=$$(printf '%s' "$$INIT" | tr -d '\r' | awk 'tolower($$1)=="mcp-session-id:" {print $$2}'); \
	if [ -z "$$SESSION" ]; then \
		if $(token_refused); then echo "$(token_refused_message)"; else echo "✗ initialize returned no Mcp-Session-Id header"; fi; \
		exit 1; \
	fi; \
	BODY=$$($(AUTH_CURL) -sf --max-time 15 "$(URL)" -X POST \
		-H "Content-Type: application/json" \
		-H "Accept: application/json, text/event-stream" \
		-H "Mcp-Session-Id: $$SESSION" \
		-H "MCP-Protocol-Version: $(MCP_LEGACY_VERSION)" \
		-d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnose","arguments":{}}}' 2>/dev/null) \
		|| { echo "✗ tools/call diagnose failed"; exit 1; }; \
	$(AUTH_CURL) -s --max-time 2 -o /dev/null "$(URL)" -X DELETE -H "Mcp-Session-Id: $$SESSION" -H "MCP-Protocol-Version: $(MCP_LEGACY_VERSION)" || true; \
	printf '%s' "$$BODY" | python3 -c '\
import sys, json; \
r = json.load(sys.stdin)["result"]; \
db = r["structuredContent"]["database"]; \
ok = db.get("accessible") is True; \
print(("✓ Database accessible: " if ok else "✗ Database NOT accessible: ") + db.get("status", "?") + " (" + db.get("path", "?") + ", pid " + str(r["structuredContent"].get("process_id")) + ")"); \
fix = db.get("fix"); \
print("  " + fix) if (not ok and fix) else None; \
sys.exit(0 if ok else 1)' \
	|| { echo "  Run: open -R \"$(APP)\"   # then turn on iMessage Max in Full Disk Access, then make restart"; exit 1; }

# The app registers the helper when it starts with --register-helper, which
# also replaces a pre-2.0 install. Arguments reach
# only a new launch, so the installed companion quits first. Only that copy:
# a build running from dist/ or a test variant keeps running. The bundle is removed,
# then copied: writing over the running helper's file makes macOS kill it.
# The old helper keeps answering until the restart, so install fails unless
# launchd runs a helper pid other than the one running before the copy;
# otherwise verify can pass against the old binary.
# Never put $(MAKE) on a line with rm, ditto or open: `make -n` runs every
# line that holds $(MAKE), so a dry run would replace the installed app.
install: app ## Build the app, install it over the released copy or to ~/Applications, register the helper, verify
	@pkill -f "$(COMPANION)" 2>/dev/null || true
	@i=0; while pgrep -f "$(COMPANION)" >/dev/null && [ $$i -lt 50 ]; do sleep 0.1; i=$$((i + 1)); done; \
	! pgrep -f "$(COMPANION)" >/dev/null || { echo "✗ The running iMessage Max did not quit within 5 s. Quit it, then run make install again."; exit 1; }
	@OLD_PID=$$($(helper_pid)); \
	mkdir -p "$(APP_DIR)" && rm -rf "$(APP)" && ditto "$(APP_BUILD)" "$(APP)" || exit 1; \
	echo "✓ Installed $(APP)"; \
	$(open_companion); \
	$(call wait_new_helper,$$OLD_PID)
	@$(MAKE) --no-print-directory verify verify-db
	@echo "Done. Database access verified."

wait-helper: ## Wait until launchd runs the helper as a pid other than OLD_PID
	@$(call wait_new_helper,$(OLD_PID))

status: ## Show service status and version
	@echo "=== Agent ==="
	@launchctl print gui/$$(id -u)/$(LAUNCHD_LABEL) 2>/dev/null | grep -E '^\s+(state|pid|program) =' \
		|| echo "Not registered"
	@echo ""
	@echo "=== Version ==="
	@"$(APP)/Contents/MacOS/imessage-max" --version 2>/dev/null || echo "App not installed"
	@echo ""
	@echo "=== Signature ==="
	@codesign -dvv "$(APP)" 2>&1 | grep -E "Signature|Authority|CDHash" || echo "Not signed"
	@echo ""
	@echo "=== Health ==="
	@$(require_server); \
	[ -n "$$LISTENER" ] || { echo "✗ Not responding"; exit 0; }; \
	BODY=$$($(call mcp_initialize,status,f)) || { \
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

logs: ## Tail the helper log
	@mkdir -p "$$(dirname "$(LOG)")" && touch "$(LOG)"
	@tail -f "$(LOG)"

clean: ## Remove debug artifacts and old logs
	@echo "Cleaning..."
	@rm -rf .build/debug .build/arm64-apple-macosx/debug .build/debug.yaml
	@echo "  Removed debug build artifacts"
	@[ ! -f "$(LOG)" ] || : > "$(LOG)"
	@echo "  Cleared the helper log"
	@echo "✓ Clean"
