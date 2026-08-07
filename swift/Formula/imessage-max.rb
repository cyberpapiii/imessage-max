class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.3.0/imessage-max-macos.tar.gz"
  # TODO(release): replace after publishing the v1.3.0 asset —
  # `shasum -a 256 imessage-max-macos.tar.gz`
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
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
