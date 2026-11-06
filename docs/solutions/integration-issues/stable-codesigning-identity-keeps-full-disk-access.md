---
title: A stable self-signed code-signing identity keeps Full Disk Access across rebuilds
date: 2026-06-11
category: integration-issues
module: imessage-max build/sign/install (Swift MCP server, launchd service)
problem_type: integration_issue
component: tooling
symptoms:
  - "Full Disk Access has to be re-granted in System Settings after almost every rebuild"
  - "chat.db reads start failing (operation not permitted) after a fresh build until FDA is re-added"
  - "codesign -dv shows Signature=adhoc / flags=0x...(adhoc) after a plain swift build"
  - "security find-identity -p codesigning shows 'iMessage Max Dev' as CSSMERR_TP_NOT_TRUSTED"
root_cause: incomplete_setup
resolution_type: environment_setup
severity: medium
tags:
  - codesign
  - full-disk-access
  - tcc
  - macos
  - launchd
  - signing-identity
---

# A stable self-signed code-signing identity keeps Full Disk Access across rebuilds

## Problem

iMessage Max reads `~/Library/Messages/chat.db`, which requires Full Disk Access.
It also needs Contacts for name resolution and Automation for sending. macOS binds
those TCC permission grants to the binary's code signature. A plain `swift build`
produces an ad-hoc signature whose identity is a per-build hash, so every rebuild
looks like a new program to TCC. The FDA grant is lost, and you have to add it
again in System Settings after each build.

## Symptoms

- After rebuilds, you must grant FDA again under System Settings, Privacy & Security.
- `chat.db` access fails ("operation not permitted") on a fresh build until you add
  FDA again.
- `codesign -dv --verbose=2 .build/release/imessage-max` shows `Signature=adhoc`.
- `security find-identity -p codesigning` lists `iMessage Max Dev` as
  `CSSMERR_TP_NOT_TRUSTED`.

## What didn't work

- Re-granting FDA in System Settings. It works for that exact binary, but the grant
  is keyed to the code signature, so the next ad-hoc rebuild invalidates it.
- Signing ad-hoc with `codesign --sign -`. Ad-hoc still produces a different identity
  each build, so TCC keeps treating it as a new app.
- Importing a self-signed cert without `-legacy`. macOS `security import` rejects
  OpenSSL 3's default PKCS#12 MAC with "MAC verification failed". You must package
  the cert with legacy algorithms: `-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES
  -macalg sha1`, or `-legacy`.

## Solution

Sign every build with a stable self-signed code-signing identity, `iMessage Max
Dev`. TCC binds the FDA grant to the signature's designated requirement, which
references the cert rather than the per-build hash, so the grant survives rebuilds.
The Makefile already does this.

```sh
cd swift
make setup-signing   # one-time: create the persistent identity
make install         # every build: build, sign, restart launchd, verify
```

`make install`'s `sign` step resolves the cert named `CERT_CN` ("iMessage Max Dev")
to its SHA-1 and runs `codesign --force --sign <sha1>`. It signs by SHA-1 because a
name is ambiguous when the keychain holds two certs with that common name. Each
rebuild carries the same stable identity, so FDA stays granted. Grant FDA once more
after the first signed build, and the grant then persists.

### Cert requirements (what `make setup-signing` must produce)

For `codesign` to accept the identity, the cert needs both key-usage
extensions and an accessible private key.

```sh
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=iMessage Max Dev" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
# package legacy, import with -T /usr/bin/codesign, then trust it:
security add-trusted-cert -r trustRoot -p codeSign cert.pem
```

## Why this works

A Full Disk Access grant names the executable's path, and TCC stores the
code signature's designated requirement (DR) with it. The binary must match
both. `make build` keeps the path fixed, as AGENTS.md describes, so the DR is
the part a rebuild can break.

- An ad-hoc signature's DR is in effect the CDHash, a hash of the exact bytes.
  Every rebuild changes the bytes, which changes the DR, so the grant no longer
  matches and FDA is lost.
- A signature from a stable cert produces a DR that references the certificate,
  which does not change between rebuilds, so the grant holds.

Signing and trust are separate steps, and that is easy to miss. `codesign --sign "iMessage
Max Dev"` succeeds even while the cert shows `NOT_TRUSTED`, as long as the cert has
both Key Usage and Extended Key Usage set and an accessible key. `add-trusted-cert`
gates Gatekeeper verification, not the ability to sign. FDA persistence therefore
works without the trust step. Add it anyway. It makes `security find-identity -v`
list the identity as valid instead of `NOT_TRUSTED`, and it removes the Makefile's
manual "trust it in Keychain Access" fallback. The extension that matters for
signing is Key Usage = Digital Signature. A cert with only Extended Key Usage is
rejected.

## Prevention

- Always deploy with `make install`, never a bare `swift build`, which signs ad-hoc.
  `make install` re-signs every time.
- Run `make setup-signing` once per machine. It is idempotent and exits early if
  signing already works.
- `make setup-signing` should automate trust end to end: package the p12 with legacy
  algorithms, import with `-T /usr/bin/codesign`, then run `add-trusted-cert -r
  trustRoot -p codeSign`, with `critical` KU and EKU. No manual Keychain Access step
  should ever be needed.
- The `diagnose` tool reports FDA and database capability state, so a lost grant is
  visible from inside the server. See "Capability contract" in `CONCEPTS.md`.

## Related

- The `plug` MCP multiplexer has the same problem. There, a stable self-signed
  identity keeps the macOS Keychain "Always Allow" ACL for upstream OAuth credentials
  from prompting again on every rebuild. The root cause is the same, a permission
  grant bound to a changing ad-hoc signature. Only the permission differs. It is TCC
  and Full Disk Access here, and Keychain in plug.
