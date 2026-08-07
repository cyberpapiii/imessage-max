class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.4.0/imessage-max-macos.tar.gz"
  # sha256 of the ad-hoc-signed imessage-max-macos.tar.gz built from v1.4.0.
  # Regenerate with `shasum -a 256 imessage-max-macos.tar.gz` if the asset is
  # ever rebuilt — the tarball must be ad-hoc signed (`codesign --sign -`),
  # not signed with the local "iMessage Max Dev" identity, which no other
  # machine trusts.
  sha256 "e2b123cbede36315a0762f15bee3a51ded6c3252ad9c2cb5361594acbb2cc333"
  license "MIT"

  depends_on :macos
  depends_on macos: :sonoma

  def install
    bin.install "imessage-max"
  end

  test do
    assert_match "iMessage Max", shell_output("#{bin}/imessage-max --version")
  end
end
