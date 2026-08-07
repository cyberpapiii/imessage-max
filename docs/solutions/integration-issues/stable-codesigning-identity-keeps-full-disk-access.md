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
Contacts and Automation are also needed, for name resolution and sending. macOS
binds those TCC permission grants to the binary's code signature. A plain `swift
build` produces an ad-hoc signature whose identity is a per-build hash, so every
rebuild looks like a brand-new program to TCC. The FDA grant is lost and has to be
re-added in System Settings after each build.

## Symptoms

- FDA must be re-granted under System Settings, Privacy & Security, after rebuilds.
- `chat.db` access fails ("operation not permitted") on a fresh build until FDA
  is re-added.
- `codesign -dv --verbose=2 .build/release/imessage-max` shows `Signature=adhoc`.
- `security find-identity -p codesigning` lists `iMessage Max Dev` as
  `CSSMERR_TP_NOT_TRUSTED`.

## What didn't work

- Re-granting FDA in System Settings. It works for that exact binary, but the grant
  is keyed to the code signature, so the next ad-hoc rebuild invalidates it.
- Signing ad-hoc with `codesign --sign -`. Ad-hoc still produces a different identity
  each build, so TCC keeps treating it as a new app.
- Importing a self-signed cert without `-legacy`. macOS `security import` rejects
  OpenSSL 3's default PKCS#12 MAC with "MAC verification failed". The cert must be
  packaged with legacy algorithms: `-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES
  -macalg sha1`, or `-legacy`.

## Solution

Sign every build with a stable self-signed code-signing identity, `iMessage Max
Dev`. TCC binds the FDA grant to the signature's designated requirement, which
references the cert rather than the per-build hash, so the grant survives rebuilds.
This is already wired into the Makefile.

```sh
cd swift
make setup-signing   # one-time: create the persistent identity
make install         # every build: build, sign, restart launchd, verify
```

`make install`'s `sign` step runs `codesign --force --sign "iMessage Max Dev"`,
so each rebuild carries the same stable identity and FDA stays granted. Grant FDA
once more after the first signed build; it then sticks.

### Cert requirements (what `make setup-signing` must produce)

For `codesign --sign "iMessage Max Dev"` to succeed, the cert needs both key-usage
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

A TCC grant, like a Keychain ACL, is keyed to the requesting executable's code
signature, specifically its designated requirement (DR).

- An ad-hoc signature's DR is essentially the CDHash, a hash of the exact bytes.
  Every rebuild changes the bytes, which changes the DR, so the grant no longer
  matches and FDA is lost.
- A signature from a stable cert produces a DR that references the certificate,
  which does not change between rebuilds, so the grant holds.

Signing and trust are separate, which is easy to miss. `codesign --sign "iMessage
Max Dev"` succeeds even while the cert shows `NOT_TRUSTED`, as long as the cert has
both Key Usage and Extended Key Usage set and an accessible key. `add-trusted-cert`
gates Gatekeeper verification, not the ability to sign. FDA persistence therefore
works without the trust step. Add it anyway: it makes `security find-identity -v`
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

- The `plug` MCP multiplexer hits the same mechanism, where a stable self-signed
  identity keeps the macOS Keychain "Always Allow" ACL for upstream OAuth credentials
  from re-prompting on every rebuild. Same root cause, a permission grant bound to a
  changing ad-hoc signature. Different permission: TCC and Full Disk Access here,
  Keychain there.
