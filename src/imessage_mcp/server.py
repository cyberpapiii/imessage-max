"""iMessage MCP Server."""

from fastmcp import FastMCP

mcp = FastMCP("iMessage MCP")


def main() -> None:
    """Run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
