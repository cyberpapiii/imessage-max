"""Link enrichment for media enrichment."""

from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, TypedDict
from urllib.parse import urlparse

import httpx
from bs4 import BeautifulSoup

TIMEOUT = 3.0  # seconds
MAX_WORKERS = 4


class LinkResult(TypedDict, total=False):
    """Result of link enrichment."""
    url: str
    domain: str
    title: Optional[str]
    description: Optional[str]


def enrich_link(url: str) -> LinkResult:
    """
    Fetch Open Graph metadata for a URL.

    Args:
        url: The URL to enrich

    Returns:
        LinkResult dict with url, domain, and optional title/description
    """
    parsed = urlparse(url)
    result: LinkResult = {
        "url": url,
        "domain": parsed.netloc,
    }

    try:
        with httpx.Client(timeout=TIMEOUT, follow_redirects=True) as client:
            response = client.get(url, headers={"User-Agent": "Mozilla/5.0"})
            response.raise_for_status()

            soup = BeautifulSoup(response.text, 'html.parser')

            # Try OG tags first
            og_title = soup.find("meta", property="og:title")
            if og_title and og_title.get("content"):
                result["title"] = og_title["content"]
            else:
                # Fall back to <title>
                title_tag = soup.find("title")
                if title_tag and title_tag.string:
                    result["title"] = title_tag.string.strip()

            og_desc = soup.find("meta", property="og:description")
            if og_desc and og_desc.get("content"):
                result["description"] = og_desc["content"]
            else:
                # Fall back to meta description
                meta_desc = soup.find("meta", attrs={"name": "description"})
                if meta_desc and meta_desc.get("content"):
                    result["description"] = meta_desc["content"]

    except Exception:
        # Return minimal result on any error
        pass

    return result


def enrich_links(urls: list[str]) -> list[LinkResult]:
    """
    Enrich multiple links in parallel.

    Args:
        urls: List of URLs to enrich

    Returns:
        List of LinkResult dicts in same order as input
    """
    if not urls:
        return []

    results: dict[int, LinkResult] = {}

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_idx = {
            executor.submit(enrich_link, url): idx
            for idx, url in enumerate(urls)
        }

        for future in as_completed(future_to_idx):
            idx = future_to_idx[future]
            try:
                results[idx] = future.result()
            except Exception:
                # Return minimal result on failure
                results[idx] = {"url": urls[idx], "domain": urlparse(urls[idx]).netloc}

    return [results[i] for i in range(len(urls))]
