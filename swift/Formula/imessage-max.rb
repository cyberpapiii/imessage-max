class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.0.0/imessage-max-macos.tar.gz"
  sha256 "ec549a62fea84be5b4f50a334152aaeb2943e910681eb2c85c2f023615460d1b"
  license "MIT"

  depends_on :macos
  depends_on macos: :ventura

  def install
    bin.install "imessage-max"
  end

  test do
    assert_match "iMessage Max", shell_output("#{bin}/imessage-max --version")
  end
end
