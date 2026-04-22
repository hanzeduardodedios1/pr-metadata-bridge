from __future__ import annotations

import logging
import os
import sys
from pathlib import Path

import requests

REQUEST_TIMEOUT_SECONDS = 20
LOGGER_NAME = "pr_metadata_bridge"
logger = logging.getLogger(LOGGER_NAME)


def _runtime_base_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path.cwd()


def _configure_logging() -> None:
    if logger.handlers:
        return

    logs_dir = _runtime_base_dir() / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)
    log_file = logs_dir / "backend.log"
    formatter = logging.Formatter(
        "%(asctime)s | %(levelname)s | %(name)s | %(message)s"
    )

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setFormatter(formatter)
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(formatter)

    logger.setLevel(logging.INFO)
    logger.addHandler(file_handler)
    logger.addHandler(stream_handler)
    logger.propagate = False


def _mask_api_key(raw_key: str) -> str:
    key = (raw_key or "").strip()
    if not key:
        return "(missing)"
    if len(key) <= 4:
        return f"{key}***"
    return f"{key[:4]}***"


_configure_logging()

def extract_text(img_bytes: bytes) -> str:
    """
    Sends image bytes to the local OCR proxy and returns extracted text.
    """
    proxy_url = os.getenv("PROXY_URL", "").strip()
    api_key = os.getenv("PROXY_API_KEY", "cf_live_83920_auth_key")
    if not proxy_url:
        logger.info("OCR Error: PROXY_URL is not set")
        return "ERROR_READING_TEXT"
    if not api_key:
        logger.info("OCR Error: PROXY_API_KEY is not set")
        return "ERROR_READING_TEXT"

    if not isinstance(img_bytes, (bytes, bytearray)) or len(img_bytes) == 0:
        logger.info("OCR Error: empty image bytes before proxy handoff")
        return "ERROR_READING_TEXT"

    try:
        logger.info(
            "OCR request: url=%s, headers=%s, file_size_bytes=%s",
            proxy_url,
            {"X-API-Key": _mask_api_key(api_key)},
            len(img_bytes),
        )
        response = requests.post(
            proxy_url,
            files={"file": ("badge-crop.jpg", img_bytes, "application/octet-stream")},
            headers={"X-API-Key": api_key},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        logger.info(
            "OCR proxy response: status_code=%s, body=%s",
            response.status_code,
            response.text,
        )
        response.raise_for_status()

        payload = response.json()
        if payload.get("status") != "success":
            logger.info("OCR Error: proxy returned non-success status: %s", payload)
            return "ERROR_READING_TEXT"

        return str(payload.get("text", "")).strip()
    except requests.exceptions.RequestException as e:
        logger.error("FATAL: Proxy connection failed: %s", e)
        logger.error("Attempted to reach URL: %s", proxy_url)
        logger.exception("OCR Connection Error")
        return "ERROR_READING_TEXT"
    except ValueError:
        logger.exception("OCR Parse Error")
        return "ERROR_READING_TEXT"
    except Exception:
        logger.exception("OCR Error")
        return "ERROR_READING_TEXT"