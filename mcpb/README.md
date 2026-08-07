# Claude Desktop MCPB metadata

This directory contains the Claude Desktop / MCPB manifest and PNG icon assets
for iMessage Max.

The manifest carries metadata only. It points Claude Desktop at an installed
`imessage-max` binary through `binary_path`, so no built macOS executable is
committed to the repository.

For a self-contained `.mcpb` package, place a signed release binary at
`mcpb/server/imessage-max` during packaging and update `server.mcp_config` to
run `${__dirname}/server/imessage-max`.
