# Claude Desktop MCPB Metadata

This directory contains the Claude Desktop / MCPB manifest and PNG icon assets
for iMessage Max.

The manifest is intentionally metadata-first. It points Claude Desktop at an
installed `imessage-max` binary selected through `binary_path`, rather than
committing a built macOS executable into the repository.

For a self-contained `.mcpb` package, place a signed release binary at
`mcpb/server/imessage-max` during packaging and update `server.mcp_config` to
run `${__dirname}/server/imessage-max`.
