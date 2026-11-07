# Claude Desktop extension (MCPB)

This directory holds the manifest and PNG icons for the iMessage Max Claude
Desktop extension, `iMessage-Max-<version>.mcpb`.

The extension ships its own copy of the signed `imessage-max` binary at
`server/imessage-max`, and the manifest runs it as
`${__dirname}/server/imessage-max` with no arguments. With no transport flag
the binary is a stdio bridge. It copies MCP traffic to the iMessage Max helper
over the socket `~/Library/Application Support/iMessage Max/mcp.sock` and never
reads Messages itself. The helper holds Full Disk Access, Contacts and
Automation, so Claude needs none of them, and installing the extension asks for
no path. When the helper is not running, the extension's first request fails
with "Open iMessage Max to start it."

The binary is left out of git. The release workflow builds the bundle with
`scripts/sign-notarize-app.sh`, which notarizes the binary and then calls:

```bash
scripts/build-mcpb.sh <signed imessage-max> <output dir>
```

`build-mcpb.sh` stages the manifest, the icons and the binary, validates and
packs them with `@anthropic-ai/mcpb`, then checks the layout, the executable
bit, the signature and the reported version of the binary inside.
