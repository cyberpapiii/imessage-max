# Releasing

A release is a notarized DMG of `iMessage Max.app`, a Claude Desktop
extension, and a Homebrew cask in `cyberpapiii/homebrew-tap` that installs
the DMG. `.github/workflows/release.yml` builds all three from a `v*` tag.

The version is set by hand in four files. `scripts/check-version.sh`
fails if they disagree, and so do `make version`, CI and
`VersionConsistencyTests`. `swift/Sources/iMessageMax/Server/Version.swift`
is the source of truth. The other files must match it.

## 1. Bump the version

Edit all four files, or run this from the repo root with the old and new
numbers filled in:

```bash
OLD=2.0.0 NEW=2.0.1
sed -i '' "s/\"$OLD\"/\"$NEW\"/" swift/Sources/iMessageMax/Server/Version.swift
sed -i '' "s|<string>$OLD</string>|<string>$NEW</string>|g" swift/Sources/Resources/Info.plist
sed -i '' "s/\"version\": \"$OLD\"/\"version\": \"$NEW\"/" mcpb/manifest.json .codex-plugin/plugin.json
scripts/check-version.sh   # prints "OK 2.0.1"
```

Add the version's entry to `CHANGELOG.md`, then commit the bump.

## 2. Run the release checks

```bash
cd swift && make release-check
```

This builds, runs the suite, and checks the version files. Before you tag,
expect a "Not on a matching tag yet" line.

## 3. Dry-run the release workflow

`.github/workflows/release.yml` builds two assets:

- `iMessage-Max-<version>.dmg`, which holds `iMessage Max.app` and an
  `/Applications` link. `scripts/sign-notarize-app.sh` builds it, signs
  it with the Developer ID, notarizes and staples both the app and the
  DMG, and checks the result before upload.
- `iMessage-Max-<version>.mcpb`, the Claude Desktop extension around the
  same signed helper.

It also writes `Casks/imessage-max.rb` with `scripts/generate-cask.sh`
from the version and the DMG's sha256, prints it, and runs `brew style`
and `brew audit --cask --strict` on it in a throwaway local tap.

Run the workflow without a tag first. A dry run builds and notarizes the
assets, uploads them and the cask as workflow artifacts, and never creates a
release or touches the tap:

```bash
gh workflow run release.yml --ref main -f dry_run=true
gh run watch "$(gh run list --workflow release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

The `dmg` job log must show `status: Accepted` three times: for the app,
the DMG, and the binary inside the extension. The "Generate the Homebrew
cask" step prints the cask. Download the `iMessage-Max-dmg` artifact from
the run page to try the DMG before you tag.

The workflow reads these repository secrets:

- `MACOS_SIGNING_IDENTITY`, the SHA-1 of the Developer ID Application
  certificate.
- `MACOS_CERTIFICATE_P12` and `MACOS_CERTIFICATE_PASS`, that certificate
  and its private key as a base64 p12, and the p12's password. The script
  imports them into a temporary keychain and deletes it on exit.
- `MACOS_NOTARY_KEY_P8`, `MACOS_NOTARY_KEY_ID`, and
  `MACOS_NOTARY_ISSUER_ID`, an App Store Connect API key as base64 p8, its
  key id, and its issuer id.
- `HOMEBREW_TAP_DEPLOY_KEY`, the private half of a deploy key with write
  access to `cyberpapiii/homebrew-tap`. Only the release job reads it.

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
git tag v2.0.1 && git push --tags
```

The workflow runs on the tag push. It fails if the tag does not match
`Version.swift`. The build checks and the `dmg` job run side by side, and
the release job starts only when both pass. It attaches the DMG and the extension to the GitHub
release, then commits `Casks/imessage-max.rb` to the tap and pushes it.
The cask reaches the tap only after the release holds the DMG it names.
Wait for the workflow to finish.

## 5. Verify the release

```bash
VERSION=2.0.1
curl -LO https://github.com/cyberpapiii/imessage-max/releases/download/v$VERSION/iMessage-Max-$VERSION.dmg
shasum -a 256 iMessage-Max-$VERSION.dmg                                               # matches the release body
spctl -a -t open --context context:primary-signature -vv iMessage-Max-$VERSION.dmg   # accepted, source=Notarized Developer ID
xcrun stapler validate iMessage-Max-$VERSION.dmg                                      # The validate action worked!
```

Then check the cask from the tap:

```bash
brew update
brew info --cask cyberpapiii/tap/imessage-max     # shows the new version
brew upgrade --cask imessage-max                  # or brew install --cask cyberpapiii/tap/imessage-max
imessage-max --version                            # iMessage Max 2.0.1
```

## The retired formula

Versions before 2.0 shipped a bare binary in `imessage-max-macos.tar.gz`
and a Homebrew formula, `imessage-max.rb`, at the tap's root. 2.0 retired
both. The tap keeps the formula with a `disable!` line that points at the
cask, so `brew install imessage-max` prints that message instead of
installing 1.8.0. Releases never update the formula again.
