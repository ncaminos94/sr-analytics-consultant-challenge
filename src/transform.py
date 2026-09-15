"""Transform raw CRM records into GA4 Measurement Protocol payloads."""

from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timezone
from typing import Any


VALID_CURRENCIES = {"USD", "EUR", "GBP", "CAD", "AUD", "JPY", "BRL", "MXN"}
GMAIL_DOMAINS = {"gmail.com", "googlemail.com"}

logger = logging.getLogger(__name__)


def hash_pii(value: str) -> str:
    """Normalize and hash a PII value for GA4's Measurement Protocol.

    Normalization: trim surrounding whitespace, lowercase, strip
    spaces/parentheses/hyphens (covers both emails and phone numbers
    without needing to detect which one it is), and for Gmail/Googlemail
    addresses, drop dots from the local part per Google's own
    Measurement Protocol guidance.
    """
    normalized = value.strip().lower()
    normalized = normalized.translate(str.maketrans("", "", " ()-"))
    if "@" in normalized:
        local, _, domain = normalized.partition("@")
        if domain in GMAIL_DOMAINS:
            normalized = f"{local.replace('.', '')}@{domain}"
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest()


def normalize_currency(currency: str | None) -> str:
    """Normalize currency code to uppercase ISO 4217."""
    if not currency:
        return "USD"
    normalized = currency.strip().upper()
    if normalized == "US":
        return "USD"
    if normalized in VALID_CURRENCIES:
        return normalized
    return "USD"


def parse_timestamp(timestamp: str | None) -> int | None:
    """Parse an ISO timestamp into microseconds since epoch."""
    if not timestamp:
        return None
    try:
        dt = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp() * 1_000_000)
    except (ValueError, TypeError):
        return None


def should_send(record: dict[str, Any]) -> bool:
    """Return False if the record should not be sent."""
    consent = record.get("consent", {})
    if consent.get("marketing") is False:
        return False
    return True


def build_items(record: dict[str, Any], *, force_positive_price: bool = False) -> list[dict[str, Any]]:
    """Map CRM line items into GA4's item schema."""
    items = []
    for raw_item in record.get("items") or []:
        item: dict[str, Any] = {}
        if raw_item.get("item_id"):
            item["item_id"] = raw_item["item_id"]
        if raw_item.get("item_name"):
            item["item_name"] = raw_item["item_name"]
        if "price" in raw_item:
            price = raw_item["price"]
            item["price"] = abs(price) if force_positive_price else price
        if "quantity" in raw_item:
            item["quantity"] = raw_item["quantity"]
        items.append(item)
    return items


def transform_record(record: dict[str, Any]) -> dict[str, Any] | None:
    """Transform a single CRM record into a GA4 MP event payload.

    Returns None if the record should be skipped.
    """
    if not should_send(record):
        return None

    client_id = record.get("client_id")
    if not client_id and record.get("user_id"):
        client_id = record["user_id"]

    if not client_id:
        return None

    timestamp_micros = parse_timestamp(record.get("timestamp"))
    currency = normalize_currency(record.get("currency"))
    event_name = record.get("event_name", "purchase")
    is_refund = event_name == "refund"

    value = record.get("value", 0)
    if is_refund:
        value = abs(value)

    params: dict[str, Any] = {
        "transaction_id": record.get("transaction_id"),
        "value": value,
        "currency": currency,
    }

    items = build_items(record, force_positive_price=is_refund)
    if items:
        params["items"] = items

    if record.get("campaign"):
        camp = record["campaign"]
        params["source"] = camp.get("source", "")
        params["medium"] = camp.get("medium", "")
        params["campaign"] = camp.get("name", "")

    event: dict[str, Any] = {
        "name": event_name,
        "params": params,
    }

    payload: dict[str, Any] = {
        "client_id": client_id,
        "user_id": record.get("user_id"),
        "events": [event],
    }

    if timestamp_micros:
        payload["timestamp_micros"] = timestamp_micros

    raw_user_data = record.get("user_data", {})
    user_data: dict[str, Any] = {}
    if raw_user_data.get("email"):
        user_data["sha256_email_address"] = [hash_pii(raw_user_data["email"])]
    if raw_user_data.get("phone"):
        user_data["sha256_phone_number"] = [hash_pii(raw_user_data["phone"])]

    if user_data:
        if record.get("user_id"):
            payload["user_data"] = user_data
        else:
            logger.warning(
                "Record %s carries user_data but has no user_id, which GA4's Measurement "
                "Protocol requires alongside it; suppressing user_data for this event",
                record.get("record_id", "<unknown>"),
            )

    return payload


def deduplicate_records(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Deduplicate records by transaction_id.

    Records without a transaction_id can't be deduplicated against anything,
    but they still represent a real event, so each is kept under its own
    synthetic key instead of being silently dropped.
    """
    seen: dict[str, dict[str, Any]] = {}
    for record in records:
        txn_id = record.get("transaction_id")
        if not txn_id:
            synthetic_key = f"__no_txn__{record.get('record_id', id(record))}"
            logger.warning(
                "Record %s has no transaction_id; keeping it under a synthetic key instead of dropping it",
                record.get("record_id", "<unknown>"),
            )
            seen[synthetic_key] = record
            continue
        existing = seen.get(txn_id)
        if not existing:
            seen[txn_id] = record
            continue
        existing_ts = parse_timestamp(existing.get("timestamp")) or 0
        new_ts = parse_timestamp(record.get("timestamp")) or 0
        if new_ts >= existing_ts:
            seen[txn_id] = record
    return list(seen.values())


def transform_all(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Transform and deduplicate a list of CRM records."""
    deduped = deduplicate_records(records)
    results = []
    for record in deduped:
        payload = transform_record(record)
        if payload:
            results.append(payload)
    return results
