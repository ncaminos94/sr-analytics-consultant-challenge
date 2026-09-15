"""Unit tests for CRM → GA4 payload transformation."""

import hashlib

import pytest

from src.transform import (
    deduplicate_records,
    hash_pii,
    normalize_currency,
    parse_timestamp,
    should_send,
    transform_all,
    transform_record,
)


class TestHashPii:
    def test_hash_pii_email(self):
        raw = "  Jane.Doe@Example.COM  "
        expected = hashlib.sha256(b"jane.doe@example.com").hexdigest()
        assert hash_pii(raw) == expected

    def test_hash_pii_phone(self):
        raw = "+1 (555) 123-4567"
        normalized = "+15551234567"
        expected = hashlib.sha256(normalized.encode()).hexdigest()
        assert hash_pii(raw) == expected


class TestNormalizeCurrency:
    def test_uppercase(self):
        assert normalize_currency("usd") == "USD"

    def test_nonstandard_code(self):
        assert normalize_currency("US") == "USD"

    def test_default_on_invalid(self):
        assert normalize_currency("INVALID") == "USD"

    def test_none_defaults_usd(self):
        assert normalize_currency(None) == "USD"


class TestParseTimestamp:
    def test_iso_with_z(self):
        result = parse_timestamp("2025-08-10T14:32:00Z")
        assert result is not None
        assert result > 0

    def test_invalid_returns_none(self):
        assert parse_timestamp("invalid-timestamp") is None

    def test_none_returns_none(self):
        assert parse_timestamp(None) is None


class TestShouldSend:
    def test_marketing_consent_false(self):
        record = {"consent": {"marketing": False, "analytics": True}}
        assert should_send(record) is False

    def test_marketing_consent_true(self):
        record = {"consent": {"marketing": True}}
        assert should_send(record) is True


class TestDeduplicate:
    def test_keeps_latest_by_timestamp(self):
        records = [
            {"transaction_id": "TXN-1", "timestamp": "2025-08-10T10:00:00Z", "value": 100},
            {"transaction_id": "TXN-1", "timestamp": "2025-08-10T16:00:00Z", "value": 200},
        ]
        result = deduplicate_records(records)
        assert len(result) == 1
        assert result[0]["value"] == 200


class TestTransformRecord:
    def test_basic_purchase(self):
        record = {
            "event_name": "purchase",
            "transaction_id": "TXN-1",
            "timestamp": "2025-08-10T14:32:00Z",
            "client_id": "123.456",
            "value": 99.99,
            "currency": "USD",
            "consent": {"marketing": True},
        }
        result = transform_record(record)
        assert result is not None
        assert result["client_id"] == "123.456"
        assert result["events"][0]["name"] == "purchase"
        assert result["events"][0]["params"]["transaction_id"] == "TXN-1"

    def test_suppressed_record(self):
        record = {
            "transaction_id": "LEAD-1",
            "client_id": "123.456",
            "consent": {"marketing": False},
        }
        assert transform_record(record) is None

    def test_fallback_identifier(self):
        record = {
            "transaction_id": "TXN-1",
            "user_id": "usr_abc",
            "consent": {"marketing": True},
        }
        result = transform_record(record)
        assert result is not None
        assert result["client_id"] == "usr_abc"


class TestTransformAll:
    def test_transform_all(self):
        records = [
            {
                "transaction_id": "TXN-1",
                "timestamp": "2025-08-10T10:00:00Z",
                "client_id": "123.456",
                "consent": {"marketing": True},
                "event_name": "purchase",
            },
            {
                "transaction_id": "TXN-1",
                "timestamp": "2025-08-10T16:00:00Z",
                "client_id": "123.456",
                "consent": {"marketing": True},
                "event_name": "purchase",
            },
            {
                "transaction_id": "LEAD-1",
                "client_id": "789.012",
                "consent": {"marketing": False},
                "event_name": "generate_lead",
            },
        ]
        results = transform_all(records)
        assert len(results) == 1
        assert results[0]["events"][0]["params"]["transaction_id"] == "TXN-1"
