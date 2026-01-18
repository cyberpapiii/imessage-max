"""Version checking with PyPI and daily caching."""

import json
import os
import time
from importlib.metadata import version, PackageNotFoundError
from pathlib import Path
from typing import Optional
import httpx

# Cache file location
CACHE_DIR = Path.home() / ".cache" / "imessage-max"
CACHE_FILE = CACHE_DIR / "version_check.json"
CACHE_TTL = 86400  # 24 hours in seconds


def _get_installed_version() -> str:
    """Get the installed package version from metadata."""
    try:
        return version("imessage-max")
    except PackageNotFoundError:
        # Fallback for development installs
        return "0.0.0"


# Current version from package metadata
CURRENT_VERSION = _get_installed_version()

# Session state - track if we've notified this session
_session_notified = False


def _parse_version(version: str) -> tuple:
    """Parse version string into comparable tuple."""
    try:
        parts = version.split(".")
        return tuple(int(p) for p in parts)
    except (ValueError, AttributeError):
        return (0, 0, 0)


def _is_newer(latest: str, current: str) -> bool:
    """Check if latest version is newer than current."""
    return _parse_version(latest) > _parse_version(current)


def _read_cache() -> Optional[dict]:
    """Read cached version info if valid."""
    try:
        if not CACHE_FILE.exists():
            return None

        with open(CACHE_FILE) as f:
            data = json.load(f)

        # Check if cache is still valid
        if time.time() - data.get("timestamp", 0) > CACHE_TTL:
            return None

        return data
    except (json.JSONDecodeError, IOError):
        return None


def _write_cache(latest_version: str) -> None:
    """Write version info to cache."""
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        with open(CACHE_FILE, "w") as f:
            json.dump({
                "latest_version": latest_version,
                "timestamp": time.time()
            }, f)
    except IOError:
        pass  # Silently fail - caching is best-effort


def _fetch_latest_version() -> Optional[str]:
    """Fetch latest version from PyPI."""
    try:
        response = httpx.get(
            "https://pypi.org/pypi/imessage-max/json",
            timeout=5.0,
            follow_redirects=True
        )
        if response.status_code == 200:
            data = response.json()
            return data.get("info", {}).get("version")
    except (httpx.RequestError, json.JSONDecodeError, KeyError):
        pass
    return None


def check_for_update() -> Optional[dict]:
    """
    Check if an update is available.

    Returns:
        Dict with update info if available, None otherwise.
        Uses daily caching to avoid spamming PyPI.
    """
    # Check cache first
    cached = _read_cache()
    if cached:
        latest = cached.get("latest_version")
        if latest and _is_newer(latest, CURRENT_VERSION):
            return {
                "available": True,
                "current_version": CURRENT_VERSION,
                "latest_version": latest,
                "update_command": "uvx --refresh imessage-max"
            }
        return None

    # Fetch from PyPI
    latest = _fetch_latest_version()
    if latest:
        _write_cache(latest)
        if _is_newer(latest, CURRENT_VERSION):
            return {
                "available": True,
                "current_version": CURRENT_VERSION,
                "latest_version": latest,
                "update_command": "uvx --refresh imessage-max"
            }

    return None


def get_update_notice_once() -> Optional[dict]:
    """
    Get update notice, but only once per session.

    Returns:
        Update info on first call if update available, None on subsequent calls.
    """
    global _session_notified

    if _session_notified:
        return None

    update_info = check_for_update()
    if update_info:
        _session_notified = True
        return update_info

    return None


def reset_session_notice() -> None:
    """Reset the session notification flag (for testing)."""
    global _session_notified
    _session_notified = False


def get_current_version() -> str:
    """Get the current installed version."""
    return CURRENT_VERSION
