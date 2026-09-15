"""GA4 Measurement Protocol client."""

from __future__ import annotations

import argparse
import logging
import os
import sys
from typing import Any

import requests
from dotenv import load_dotenv

load_dotenv()

logger = logging.getLogger(__name__)

GA4_COLLECT_URL = "https://www.google-analytics.com/mp/collect"
GA4_DEBUG_URL = "https://www.google-analytics.com/debug/mp/collect"


def get_config() -> dict[str, str]:
    """Load GA4 configuration from environment variables."""
    measurement_id = os.getenv("GA4_MEASUREMENT_ID", "")
    api_secret = os.getenv("GA4_API_SECRET", "")
    if not measurement_id or not api_secret:
        raise ValueError(
            "GA4_MEASUREMENT_ID and GA4_API_SECRET must be set in .env"
        )
    return {
        "measurement_id": measurement_id,
        "api_secret": api_secret,
        "debug": os.getenv("GA4_DEBUG", "true").lower() == "true",
        "sgtm_url": os.getenv("SGTM_URL", "https://localhost"),
        "offline_route": os.getenv("OFFLINE_ROUTE", "direct"),
    }


def build_url(config: dict[str, str], debug: bool | None = None) -> str:
    """Build the GA4 collect or debug endpoint URL."""
    use_debug = debug if debug is not None else config["debug"]
    base = GA4_DEBUG_URL if use_debug else GA4_COLLECT_URL
    return (
        f"{base}?measurement_id={config['measurement_id']}"
        f"&api_secret={config['api_secret']}"
    )


def send_payload(
    payload: dict[str, Any],
    config: dict[str, str] | None = None,
    debug: bool | None = None,
) -> dict[str, Any]:
    """Send a single payload to GA4 Measurement Protocol.

    Returns the response body (debug endpoint returns validation messages).
    """
    config = config or get_config()
    url = build_url(config, debug=debug)

    logger.info("Sending event '%s' for client_id=%s", 
                payload["events"][0]["name"], payload.get("client_id"))

    response = requests.post(url, json=payload, timeout=30)
    response.raise_for_status()

    if (debug if debug is not None else config["debug"]):
        return response.json()
    return {"status": "sent", "http_status": response.status_code}


def send_batch(
    payloads: list[dict[str, Any]],
    config: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    """Send multiple payloads to GA4."""
    config = config or get_config()
    results = []

    for payload in payloads:
        result: dict[str, Any] = {"payload": payload}

        if config["debug"]:
            validation = send_payload(payload, config, debug=True)
            result["validation"] = validation

            messages = validation.get("validationMessages", [])
            if messages:
                logger.warning("Validation issues: %s", messages)
                result["status"] = "validation_failed"
                results.append(result)
                continue

        send_payload(payload, config, debug=False)
        result["status"] = "sent"
        results.append(result)

    return results


def validate_sample() -> None:
    """Send a sample payload to the debug endpoint for quick validation."""
    sample = {
        "client_id": "test.1234567890",
        "events": [{
            "name": "test_event",
            "params": {"test_param": "hello"},
        }],
    }
    config = get_config()
    result = send_payload(sample, config, debug=True)
    print("Validation result:")
    print(result)


def main() -> None:
    parser = argparse.ArgumentParser(description="GA4 Measurement Protocol client")
    parser.add_argument("--validate-sample", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)

    if args.validate_sample:
        validate_sample()
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
