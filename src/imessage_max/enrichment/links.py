"""Link enrichment for media enrichment."""

from typing import Optional, TypedDict, List


class LinkMetadata(TypedDict):
    """Result of link enrichment."""
    url: str
    title: Optional[str]
    description: Optional[str]
    image_url: Optional[str]


def enrich_links(text: str) -> List[LinkMetadata]:
    """
    Extract and enrich links found in message text.

    Args:
        text: Message text that may contain URLs

    Returns:
        List of LinkMetadata dicts for each URL found
    """
    # Stub implementation - will be completed in Task 5
    return []
