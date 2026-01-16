"""iMessage MCP Server."""

from fastmcp import FastMCP

mcp = FastMCP("iMessage MCP")


def main():
    """Run the MCP server."""
    mcp.run()


if __name__ == "__main__":
    main()
