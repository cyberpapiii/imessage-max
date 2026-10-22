# Menu bar companion validation — October 12, 2026

## Delivered

Installed and launched `~/Applications/iMessage Max.app`, locally signed with the existing iMessage Max Dev identity. The reproducible bundle is also in `dist/iMessage Max.app`. The companion has no third-party dependencies. Its own release executable is about 1.1 MiB; the complete app, including the existing server helper and icon, is about 28 MiB.

The existing launch agent still names the repository's canonical `.build/release/imessage-max` path. No Full Disk Access grant was moved. The final `make install` verified both MCP eras and actual database access on the running helper, PID 66423 at that check.

## Checks

| Check | Evidence |
| --- | --- |
| Companion behavioral tests | 15 passed, including readiness distinctions, modern headers/reply validation, equals-form options, IPv6, template fidelity, ownership classification, output bounds, timeout, and cancellation of an already-running child whose PID disappeared. |
| Existing server suite | 541 tests, one skipped, zero failures. |
| Build/signature | Release build and `codesign --verify --deep --strict` passed for the installed app. |
| Home | Native CUA inspection and screenshot: Ready to read; Messages Ready; Contact names Ready; Sending Not checked. |
| Setup | Native expansion showed explicit Automation setup and clearly stated that setup sends no message. |
| Connection | Address and Codex configuration copied through the native UI; pasteboard contents matched the configured loopback address and TOML snippet. |
| Diagnostics | Report copied through UI; contained only version, status, local endpoint, and check timing. Updated accessibility entries named Version, Live inbox, and Checked. |
| Preferences | Native switch inspected, off by default. No login-item preference changed during verification. |
| Stop | UI entered Taking a break; launchctl no longer found the service and the port refused connections. |
| Start | UI returned to Ready to read; the new helper read Messages and resolved contacts. |
| Restart | After adopting the canonical bootout/bootstrap sequence, the native action returned to Ready to read in about 2.3 seconds including CUA observation overhead. |
| Escape/reopen | Escape collapsed the expanded Preferences section. A second Escape removed the target window from inspection; reopening the app restored the same panel with collapsed sections. |
| Persistent chrome | Native accessibility hierarchy placed header and footer outside the scrolling body. |
| Footprint | One idle process snapshot: 82,368 KiB RSS, 0.0% CPU. This is a snapshot, not a sustained benchmark. |
| Check timing | Warm diagnostic report recorded 20 ms; initial contact loading took roughly half a second. These are service-check measurements, not frame-time measurements. |
| Review | A fresh reviewer identified configuration, recovery, stale-response, duration, and cancellation issues. All important findings were fixed; final review found none remaining. |

## Design review and limits

The running native home, setup, connection, details, and preferences surfaces were inspected. The original speech-bubble face was corrected after a screenshot revealed overlapping path contours. Its geometry now remains continuous between states. Labels and control sizes use the documented tokens; status is communicated through words and symbols as well as color. Settings and help use the same inset-card vocabulary as the home screen.

Motion durations remain starting estimates: 160 ms controls, 280 ms sections, 180 ms exits, and a 600 ms rare acknowledgement. No continuous character loop exists. Reduce Motion and Reduce Transparency paths and native accessibility labels were reviewed in source. The current dark appearance was inspected live; separate light-mode, reduced-motion, VoiceOver, half-speed recording, and frame-time profiling runs were not performed. Native Tab focus follows the Mac's keyboard-navigation settings; Escape was exercised directly.

At initial delivery, Automation remained unverified on this Mac. The setup repair below subsequently verified the existing Automation grant through the actual running daemon. No test message was sent and no new privacy permission was granted. Fresh-install template rendering is tested; installation on a second clean Mac was not exercised. Login-item registration and notarized distribution are also not claimed.

During the first kickstart restart test, the existing server emitted `freed pointer was not the last allocation` while shutting down and launchd applied its 30-second crash throttle. The companion now follows the repository's existing unload/load restart workflow, which recovered promptly. This work does not claim to fix that underlying server/toolchain shutdown allocator issue.

## Setup repair and current verification

The reported setup failure reproduced as an unfinished sending step after a misleading permission-check notice. Messages was not running. Apple's Automation permission API requires a running target, but the previous mapping treated the target-not-found result as consent not determined. The original foreground CLI request also inherited the companion's TCC responsibility, which did not establish access for the independent launchd service.

The companion now opens Messages before its Automation check. Explicit permission requests execute inside the real daemon through `POST /setup/permissions`, independently of MCP tools and sending. The route requires a native marker, rejects every browser Origin, restricts request size and fields, and is disabled on non-loopback listeners. An actor serializes permission prompts. The response includes the daemon PID; the companion checks that identity and rechecks capabilities before saying setup succeeded. Default daemon startup and ordinary diagnose calls remain non-prompting.

| Final check | Evidence |
| --- | --- |
| Companion tests | 19 passed, including native request construction, PID and permission binding, denied replies, and setup priority when Messages is closed. |
| Server tests | 548 tests, one skipped, zero failures; seven setup cases cover browser and unmarked rejection, strict payload bounds, loopback restriction, and permission status mapping. |
| Deployment | `make install` completed; legacy and modern lanes healthy, actual Messages database accessible, running signed helper PID 89963. Installed app passed `codesign --verify --deep --strict`. |
| Closed-target recovery | Quit the Messages instance opened for diagnosis. Native companion showed Ready to read, Sending Not checked, and Check sending. Clicking Check sending opened Messages and changed the native panel to Ready to help, all three rows Ready, and Sending is ready. |
| Actual permission identity | Native setup request returned authorized Automation with PID 89963, matching `launchctl print` for local.imessage-max. No companion-spawned permission helper was used. |
| Live browser boundary | Requests with a localhost Origin or without the native marker both returned HTTP 403. |

The existing Automation grant is verified; delivery of a message is not. A fresh macOS consent prompt and clean-machine Contacts/Full Disk Access setup were not exercised. Those prompt paths have injected behavioral tests, and the installed app checks their outcome against live daemon diagnosis.
