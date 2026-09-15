"""CRM event ingestion pipeline — entry point."""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path

from dotenv import load_dotenv

from src.send_ga4 import get_config, send_batch
from src.transform import transform_all

load_dotenv()

logger = logging.getLogger(__name__)


def load_crm_events(path: str | Path) -> list[dict]:
    """Load CRM events from a JSON file."""
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    events_path = os.getenv("CRM_EVENTS_PATH", "data/crm_events.json")
    logger.info("Loading CRM events from %s", events_path)

    records = load_crm_events(events_path)
    logger.info("Loaded %d raw records", len(records))

    payloads = transform_all(records)
    logger.info("Transformed %d records into GA4 payloads", len(payloads))

    if not payloads:
        logger.warning("No payloads to send — check transform logic and consent filters")
        sys.exit(1)

    config = get_config()
    results = send_batch(payloads, config)

    sent = sum(1 for r in results if r.get("status") == "sent")
    logger.info("Pipeline complete: %d events sent", sent)


if __name__ == "__main__":
    main()
