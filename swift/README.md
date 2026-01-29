# iMessage Max (Swift)

Native macOS MCP server for iMessage, built in Swift for optimal performance.

## Building

```bash
swift build -c release
# Binary: .build/release/imessage-max
```

## Requirements

- macOS 13+ (Ventura)
- Xcode Command Line Tools or full Xcode

## Architecture

### Core Components

```
Sources/iMessageMax/
├── main.swift              # Entry point, CLI parsing
├── Server/
│   ├── MCPServer.swift     # Server lifecycle
│   └── ToolRegistry.swift  # Tool registration
├── Database/
│   ├── Database.swift      # SQLite wrapper
│   └── QueryBuilder.swift  # SQL construction
├── Tools/                  # 12 MCP tools
│   ├── FindChat.swift
│   ├── GetMessages.swift
│   ├── ListChats.swift
│   ├── Search.swift
│   ├── GetContext.swift
│   ├── GetActiveConversations.swift
│   ├── ListAttachments.swift
│   ├── GetUnread.swift
│   ├── Send.swift
│   ├── GetAttachment.swift
│   ├── Update.swift
│   └── Diagnose.swift
├── Contacts/
│   └── ContactResolver.swift  # CNContactStore integration
├── Enrichment/
│   ├── ImageProcessor.swift   # Core Image resizing
│   ├── VideoProcessor.swift   # AVFoundation metadata
│   └── AudioProcessor.swift   # Audio duration extraction
└── Utilities/
    ├── AppleTime.swift        # Apple epoch conversion
    ├── PhoneUtils.swift       # Phone number formatting
    └── TimeUtils.swift        # ISO/relative time formatting
```

### Dependencies

- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) - Protocol implementation
- [Swift Argument Parser](https://github.com/apple/swift-argument-parser) - CLI interface

### Key Design Decisions

1. **Raw SQLite3** - Direct C API calls for maximum performance
2. **Core Image** - GPU-accelerated image resizing for attachment variants
3. **CNContactStore** - Native contact resolution without Python/PyObjC
4. **Typedstream Parsing** - Proper extraction of text from iMessage's `attributedBody` format
5. **MCP Image Content** - Images returned as proper MCP image type, not base64 in JSON

## Usage

### stdio Mode (Default)

```bash
./imessage-max
```

### HTTP Mode

```bash
./imessage-max --http --port 8080
```

### CLI Options

```
USAGE: imessage-max [--http] [--port <port>] [--version]

OPTIONS:
  --http                  Run in HTTP mode instead of stdio
  --port <port>           HTTP port (default: 8080)
  --version               Show version
  -h, --help              Show help
```

## Testing

```bash
# Run unit tests
swift test

# Test MCP protocol manually
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | ./imessage-max
```

## Performance

The Swift implementation offers significant improvements over the Python version:

- **Startup**: ~50ms vs ~2s (no interpreter startup)
- **Memory**: ~15MB vs ~80MB (no runtime overhead)
- **Image Processing**: GPU-accelerated via Core Image
- **Binary Size**: ~10MB self-contained

## License

MIT
