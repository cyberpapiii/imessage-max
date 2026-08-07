# Claude Desktop MCPB metadata

This directory contains the Claude Desktop / MCPB manifest and PNG icon assets
for iMessage Max.

The manifest carries metadata only. Runtime uses `user_config.binary_path`
(`${user_config.binary_path}` in `mcp_config.command`). No built macOS
executable is committed to the repository.

`server.entry_point` (`server/imessage-max`) is the packaging-time path for a
self-contained `.mcpb` bundle. It is intentionally absent in git. To package:

```bash
mkdir -p mcpb/server
cp /path/to/signed/imessage-max mcpb/server/imessage-max
# then point mcp_config.command at ${__dirname}/server/imessage-max
```
