"""Integration tests for iMessage MCP Pro.

These tests run against the real ~/Library/Messages/chat.db database
and are skipped by default. To run them, use:

    pytest tests/integration/ -v --real-db

Requirements:
- macOS with Full Disk Access enabled for the terminal
- Real iMessage chat.db at ~/Library/Messages/chat.db
"""
