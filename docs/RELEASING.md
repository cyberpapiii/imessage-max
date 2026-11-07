# Releasing

The version is set by hand in five places. `scripts/check-version.sh`
fails if they disagree, and so do `make version`, CI and
`VersionConsistencyTests`. `swift/Sources/iMessageMax/Server/Version.swift`
is the source of truth. The other sites must match it.

## 1. Bump the version

Edit all five sites, or run this from the repo root with the old and new
numbers filled in:

```bash
OLD=1.4.2 NEW=1.4.3
sed -i '' "s/\"$OLD\"/\"$NEW\"/" swift/Sources/iMessageMax/Server/Version.swift
sed -i '' "s|<string>$OLD</string>|<string>$NEW</string>|g" swift/Sources/Resources/Info.plist
sed -i '' "s/\"version\": \"$OLD\"/\"version\": \"$NEW\"/" mcpb/manifest.json .codex-plugin/plugin.json
sed -i '' "s/v$OLD\//v$NEW\//; s/version \"$OLD\"/version \"$NEW\"/; s/from v$OLD/from v$NEW/" swift/Formula/imessage-max.rb
scripts/check-version.sh   # prints "OK 1.4.3"
```

The Formula `sha256` is unknown until the release asset exists. Step 5 fills it in. `scripts/check-version.sh` checks only the version and the url tag.

Commit the bump.

## 2. Run the release checks

```bash
cd swift && make release-check
```

This builds, runs the suite, checks the five version sites, and checks
the Formula's syntax. Before you tag, expect a "Not on a matching tag yet"
line.

## 3. Dry-run the release workflow

`.github/workflows/release.yml` builds two assets:

- `imessage-max-macos.tar.gz`, the bare server binary, signed ad hoc. The
  Formula installs it.
- `iMessage-Max-<version>.dmg`, which holds `iMessage Max.app` and an
  `/Applications` link. `scripts/sign-notarize-app.sh` builds it, signs
  it with the Developer ID, notarizes and staples both the app and the
  DMG, and checks the result before upload.

Run the workflow without a tag first. A dry run builds and notarizes both
assets, uploads them as workflow artifacts, and never creates a release:

```bash
gh workflow run release.yml --ref main -f dry_run=true
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

The `dmg` job log must show `status: Accepted` twice, once for the app and
once for the DMG. Download the `iMessage-Max-dmg` artifact from the run
page to try the DMG before you tag.

The `dmg` job reads these repository secrets:

- `MACOS_SIGNING_IDENTITY`, the SHA-1 of the Developer ID Application
  certificate.
- `MACOS_CERTIFICATE_P12` and `MACOS_CERTIFICATE_PASS`, that certificate
  and its private key as a base64 p12, and the p12's password. The script
  imports them into a temporary keychain and deletes it on exit.
- `MACOS_NOTARY_KEY_P8`, `MACOS_NOTARY_KEY_ID`, and
  `MACOS_NOTARY_ISSUER_ID`, an App Store Connect API key as base64 p8, its
  key id, and its issuer id.

To build the DMG on your Mac with the identity already in your keychain,
pass `--local`. It skips the temporary keychain and notarizes for real:

```bash
MACOS_SIGNING_IDENTITY=<certificate SHA-1> \
MACOS_NOTARY_KEY_P8="$(base64 -i AuthKey_<key id>.p8)" \
MACOS_NOTARY_KEY_ID=<key id> MACOS_NOTARY_ISSUER_ID=<issuer id> \
scripts/sign-notarize-app.sh --local dist
```

The script fails if the helper links `libswiftCompatibilitySpan.dylib`
non-weak, because macOS 15 has no copy of that library and the helper would
not launch there. Xcode 26 links it weak. Xcode 27.2 links it strongly, so
`--local` fails on a Mac with Xcode 27 until the build embeds the library or
links it weak.

## 4. Tag and push

```bash
git tag v1.4.3 && git push --tags
```

The workflow runs on the tag push. It fails if the tag does not match
`Version.swift`, then attaches the tarball and the DMG to the GitHub
release. Wait for it to finish.

## 5. Verify the release assets

```bash
VERSION=1.4.3
curl -LO https://github.com/cyberpapiii/imessage-max/releases/download/v$VERSION/imessage-max-macos.tar.gz
shasum -a 256 imessage-max-macos.tar.gz
mkdir -p /tmp/imessage-max-release && tar -xzf imessage-max-macos.tar.gz -C /tmp/imessage-max-release
/tmp/imessage-max-release/imessage-max --version      # iMessage Max 1.4.3
codesign -dv /tmp/imessage-max-release/imessage-max 2>&1 | grep Signature   # Signature=adhoc
```

The digest must match the one in the GitHub release body. The tarball
binary stays ad hoc signed until the DMG replaces it.

```bash
curl -LO https://github.com/cyberpapiii/imessage-max/releases/download/v$VERSION/iMessage-Max-$VERSION.dmg
spctl -a -t open --context context:primary-signature -vv iMessage-Max-$VERSION.dmg   # accepted, source=Notarized Developer ID
xcrun stapler validate iMessage-Max-$VERSION.dmg                                      # The validate action worked!
```

Do not run `brew install --build-from-source swift/Formula/imessage-max.rb`.
Homebrew 6 refuses a path argument when a formula of that name already
exists in a tap (`cyberpapiii/tap/imessage-max`), and the Formula installs
the prebuilt tarball anyway, so there is nothing to build.

## 6. Update the Formula and publish it to the tap

In `swift/Formula/imessage-max.rb`, set `url` to the new asset and `sha256`
to the digest from step 5. Step 1 already bumped `version`. Commit the change.

Then copy it into the tap checkout, commit, and push. The operator pushes
this, not CI. The tap keeps formulas at the repo root
(`/opt/homebrew/Library/Taps/cyberpapiii/homebrew-tap/imessage-max.rb`):

```bash
TAP=$(brew --repository cyberpapiii/tap)
cp swift/Formula/imessage-max.rb "$TAP/imessage-max.rb"
HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 cyberpapiii/tap/imessage-max >/dev/null
git -C "$TAP" commit -am "imessage-max $VERSION"
git -C "$TAP" push
brew update
brew install cyberpapiii/tap/imessage-max   # or brew upgrade imessage-max
brew test imessage-max
```

`brew test` runs `imessage-max --version` and matches `iMessage Max`.

## 7. Close out

Remove any provisional line from `CHANGELOG.md` (for example a note that
the Formula still points at an older tarball) and commit it with the
Formula change.
