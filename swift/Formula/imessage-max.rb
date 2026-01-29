class ImessageMax < Formula
  desc "MCP server for iMessage - AI assistant integration"
  homepage "https://github.com/cyberpapiii/imessage-max"
  url "https://github.com/cyberpapiii/imessage-max/releases/download/v1.0.2/imessage-max-macos.tar.gz"
  sha256 "9359d6e8142b3473dd55877cd6a1f38f7629751f59f24e72600b17d0adce2e68"
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
