"""Tests for link enrichment."""

import pytest
from imessage_max.enrichment.links import enrich_link, enrich_links


class TestEnrichLink:
    """Tests for enrich_link function."""

    def test_enrich_link_extracts_og_tags(self, httpx_mock):
        """Should extract Open Graph title and description."""
        httpx_mock.add_response(
            url="https://example.com/article",
            html='''
            <html>
            <head>
                <meta property="og:title" content="Test Article Title">
                <meta property="og:description" content="This is the article description.">
            </head>
            <body></body>
            </html>
            '''
        )

        result = enrich_link("https://example.com/article")

        assert result["url"] == "https://example.com/article"
        assert result["title"] == "Test Article Title"
        assert result["description"] == "This is the article description."
        assert result["domain"] == "example.com"

    def test_enrich_link_falls_back_to_title_tag(self, httpx_mock):
        """Should fall back to <title> if no OG title."""
        httpx_mock.add_response(
            url="https://example.com/page",
            html='''
            <html>
            <head>
                <title>Page Title</title>
            </head>
            <body></body>
            </html>
            '''
        )

        result = enrich_link("https://example.com/page")

        assert result["title"] == "Page Title"
        assert result["domain"] == "example.com"

    def test_enrich_link_handles_missing_metadata(self, httpx_mock):
        """Should return minimal data when no metadata found."""
        httpx_mock.add_response(
            url="https://example.com/bare",
            html="<html><body>Just content</body></html>"
        )

        result = enrich_link("https://example.com/bare")

        assert result["url"] == "https://example.com/bare"
        assert result["domain"] == "example.com"
        assert result.get("title") is None
        assert result.get("description") is None

    def test_enrich_link_handles_timeout(self, httpx_mock):
        """Should return minimal data on timeout."""
        import httpx
        httpx_mock.add_exception(httpx.TimeoutException("timeout"))

        result = enrich_link("https://slow.example.com/page")

        assert result["url"] == "https://slow.example.com/page"
        assert result["domain"] == "slow.example.com"

    def test_enrich_link_handles_error(self, httpx_mock):
        """Should return minimal data on HTTP error."""
        httpx_mock.add_response(url="https://example.com/404", status_code=404)

        result = enrich_link("https://example.com/404")

        assert result["url"] == "https://example.com/404"
        assert result["domain"] == "example.com"


class TestEnrichLinks:
    """Tests for enrich_links batch function."""

    def test_enrich_links_processes_multiple(self, httpx_mock):
        """Should process multiple links in parallel."""
        httpx_mock.add_response(
            url="https://a.com/",
            html='<html><head><meta property="og:title" content="A"></head></html>'
        )
        httpx_mock.add_response(
            url="https://b.com/",
            html='<html><head><meta property="og:title" content="B"></head></html>'
        )

        results = enrich_links(["https://a.com/", "https://b.com/"])

        assert len(results) == 2
        assert results[0]["title"] == "A"
        assert results[1]["title"] == "B"

    def test_enrich_links_handles_empty_list(self):
        """Should return empty list for empty input."""
        results = enrich_links([])
        assert results == []
