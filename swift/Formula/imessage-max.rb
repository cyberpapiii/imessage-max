class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.7.1/imessage-max-macos.tar.gz"
  # version is redundant with the url's tag segment; kept because
  # scripts/check-version.sh and VersionConsistencyTests read it.
  version "1.7.1"
  # sha256 of the ad-hoc-signed imessage-max-macos.tar.gz built from v1.7.1.
  # Regenerate with `shasum -a 256 imessage-max-macos.tar.gz` if the asset is
  # ever rebuilt. The tarball must be ad-hoc signed (`codesign --sign -`),
  # not signed with the local "iMessage Max Dev" identity, which no other
  # machine trusts.
  sha256 "dfe6bd908dd6ddb3f414d244c4c3f83779ba6e7f1ea977efa7fc545b62043414"
  license "MIT"

  depends_on arch: :arm64
  depends_on :macos
  depends_on macos: :sequoia

  def install
    bin.install "imessage-max"
  end

  test do
    assert_match "iMessage Max", shell_output("#{bin}/imessage-max --version")
  end
end
