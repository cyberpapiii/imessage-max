"""Tests for phone number utilities."""

import pytest
from imessage_max.phone import (
    normalize_to_e164,
    format_phone_display,
    is_phone_number,
    is_email,
)


class TestNormalizeToE164:
    def test_us_10_digit(self):
        # Use 202 area code (Washington DC) - a valid area code
        assert normalize_to_e164("2025551234") == "+12025551234"

    def test_us_with_country_code(self):
        assert normalize_to_e164("12025551234") == "+12025551234"

    def test_already_e164(self):
        assert normalize_to_e164("+12025551234") == "+12025551234"

    def test_formatted_number(self):
        assert normalize_to_e164("(202) 555-1234") == "+12025551234"

    def test_invalid_number(self):
        assert normalize_to_e164("invalid") is None

    def test_short_number(self):
        assert normalize_to_e164("123") is None


class TestFormatPhoneDisplay:
    def test_us_number(self):
        result = format_phone_display("+12025551234")
        assert "202" in result
        assert "555" in result
        assert "1234" in result

    def test_invalid_returns_original(self):
        assert format_phone_display("invalid") == "invalid"


class TestIsPhoneNumber:
    def test_valid_phone(self):
        assert is_phone_number("+12025551234") is True
        assert is_phone_number("202-555-1234") is True

    def test_invalid_phone(self):
        assert is_phone_number("hello") is False
        assert is_phone_number("123") is False


class TestIsEmail:
    def test_valid_email(self):
        assert is_email("test@example.com") is True

    def test_invalid_email(self):
        assert is_email("notanemail") is False
        assert is_email("missing@domain") is False
