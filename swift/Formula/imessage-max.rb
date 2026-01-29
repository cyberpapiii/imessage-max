class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.0.1/imessage-max-macos.tar.gz"
  sha256 "b9f328d0f7325ad5b6c07bf020411eed4a72ae1127784f2f0ecb4108b522f2b5"
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
