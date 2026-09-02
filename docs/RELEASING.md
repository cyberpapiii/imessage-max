# Releasing

The version is written by hand in five places. `scripts/check-version.sh`
(also `make version`, CI, and `VersionConsistencyTests`) fails if they
disagree. `swift/Sources/iMessageMax/Server/Version.swift` is the source
of truth; the other sites must match it.

## 1. Bump the version

Edit all five sites, or run this from the repo root with the old and new
numbers filled in:

```bash
OLD=1.4.2 NEW=1.4.3
sed -i '' "s/\"$OLD\"/\"$NEW\"/" swift/Sources/iMessageMax/Server/Version.swift
sed -i '' "s|<string>$OLD</string>|<string>$NEW</string>|g" swift/Sources/Resources/Info.plist
sed -i '' "s/\"version\": \"$OLD\"/\"version\": \"$NEW\"/" mcpb/manifest.json .codex-plugin/plugin.json
sed -i '' "s/v$OLD\//v$NEW\//; s/version \"$OLD\"/version \"$NEW\"/" swift/Formula/imessage-max.rb
scripts/check-version.sh   # prints "OK 1.4.3"
```

The Formula `sha256` cannot be known until the release asset exists; step 4 fills it in. `scripts/check-version.sh` checks the version and url tag only.

Commit the bump.

## 2. Run the release checks

```bash
cd swift && make release-check
```

This builds, runs the suite, checks the five version sites, and syntax
checks the Formula. The "Not on a matching tag yet" line is expected
before you tag.

## 3. Tag and push

```bash
git tag v1.4.3 && git push --tags
```

`.github/workflows/release.yml` builds on the tag push and attaches
`imessage-max-macos.tar.gz` to the GitHub release. Wait for it to finish.

## 4. Verify the release asset

```bash
VERSION=1.4.3
curl -LO https://github.com/cyberpapiii/imessage-max/releases/download/v$VERSION/imessage-max-macos.tar.gz
shasum -a 256 imessage-max-macos.tar.gz
mkdir -p /tmp/imessage-max-release && tar -xzf imessage-max-macos.tar.gz -C /tmp/imessage-max-release
/tmp/imessage-max-release/imessage-max --version      # iMessage Max 1.4.3
codesign -dv /tmp/imessage-max-release/imessage-max 2>&1 | grep Signature   # Signature=adhoc
```

The digest must match the one in the GitHub release body. `Signature=adhoc`
is required: the Formula ships this binary as-is, and a binary signed with
the local "iMessage Max Dev" identity is trusted by no other machine.

Do not run `brew install --build-from-source swift/Formula/imessage-max.rb`.
Homebrew 6 refuses a path argument when a formula of that name already
exists in a tap (`cyberpapiii/tap/imessage-max`), and the Formula installs
the prebuilt tarball anyway, so there is nothing to build.

## 5. Update the Formula and publish it to the tap

In `swift/Formula/imessage-max.rb`, set `url` to the new asset and `sha256`
to the digest from step 4 (`version` was already bumped in step 1). Commit.

Then copy it into the tap checkout, commit, and push (this is the operator's
push, not CI's). The tap keeps formulas at the repo root
(`/opt/homebrew/Library/Taps/cyberpapiii/homebrew-tap/imessage-max.rb`):

```bash
TAP=$(brew --repository cyberpapiii/tap)
cp swift/Formula/imessage-max.rb "$TAP/imessage-max.rb"
git -C "$TAP" commit -am "imessage-max $VERSION"
git -C "$TAP" push
brew update
brew install cyberpapiii/tap/imessage-max   # or brew upgrade imessage-max
brew test imessage-max
```

`brew test` runs `imessage-max --version` and matches `iMessage Max`.

## 6. Close out

Remove any provisional line from `CHANGELOG.md` (for example a note that
the Formula still points at an older tarball) and commit it with the
Formula change.
