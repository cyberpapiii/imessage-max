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

## 4. Update the Homebrew Formula

```bash
curl -LO https://github.com/cyberpapiii/imessage-max/releases/download/v1.4.3/imessage-max-macos.tar.gz
shasum -a 256 imessage-max-macos.tar.gz
```

In `swift/Formula/imessage-max.rb`, set `url` to the new release asset
and `sha256` to the printed digest. Then confirm the package installs and
its test passes (`--version` prints `iMessage Max <version>`, which the
Formula test matches):

```bash
brew install --build-from-source swift/Formula/imessage-max.rb
brew test imessage-max
```

Commit the Formula change.
