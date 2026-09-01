class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.4.1/imessage-max-macos.tar.gz"
  # sha256 of the ad-hoc-signed imessage-max-macos.tar.gz built from v1.4.1.
  # Regenerate with `shasum -a 256 imessage-max-macos.tar.gz` if the asset is
  # ever rebuilt. The tarball must be ad-hoc signed (`codesign --sign -`),
  # not signed with the local "iMessage Max Dev" identity, which no other
  # machine trusts.
  sha256 "20ac8bead397bf21f778a44ab90161998feb666e6fe755d4f52ecbc52a441d58"
  license "MIT"

  depends_on :macos
  depends_on macos: :sequoia
  depends_on arch: :arm64

  def install
    bin.install "imessage-max"
  end

  test do
    assert_match "iMessage Max", shell_output("#{bin}/imessage-max --version")
  end
end
