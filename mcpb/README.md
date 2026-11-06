# Claude Desktop MCPB metadata

This directory contains the Claude Desktop / MCPB manifest and PNG icon assets
for iMessage Max.

The manifest holds only metadata. At runtime, `mcp_config.command` is
`${user_config.binary_path}`, so the client runs the binary at
`user_config.binary_path`. The repository does not include a built macOS
executable.

`server.entry_point`, set to `server/imessage-max`, is where the binary goes
when you package a self-contained `.mcpb` bundle. That file is left out of git
on purpose. To package:

```bash
mkdir -p mcpb/server
cp /path/to/signed/imessage-max mcpb/server/imessage-max
# then point mcp_config.command at ${__dirname}/server/imessage-max
```
