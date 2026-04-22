import multiprocessing
import logging
import os
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from pydantic import BaseModel
from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
import requests
import uvicorn
from dotenv import load_dotenv
from app.services.exif_logic import process_manifest_in_place
try:
    from platformdirs import user_log_path
except ImportError:  # pragma: no cover - optional dependency fallback
    user_log_path = None

bundle_dir = (
    Path(sys.executable).parent
    if getattr(sys, "frozen", False)
    else Path(__file__).parent
)
load_dotenv(bundle_dir / ".env")

REQUEST_TIMEOUT_SECONDS = 20
LOGGER_NAME = "pr_metadata_bridge"
logger = logging.getLogger(LOGGER_NAME)


def _configure_logging() -> None:
    if logger.handlers:
        return

    if user_log_path is not None:
        logs_dir = user_log_path(appname="CaptionFast", ensure_exists=True)
    else:
        local_app_data = Path(
            os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local"))
        )
        logs_dir = local_app_data / "CaptionFast" / "logs"

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


def _summarize_manifest(manifest: dict[str, str]) -> tuple[list[str], dict[str, str]]:
    filenames: list[str] = []
    preflight: dict[str, str] = {}
    for file_path in manifest.keys():
        path_obj = Path(file_path)
        filenames.append(path_obj.name or file_path)
        if path_obj.exists():
            preflight[file_path] = "ready"
        else:
            preflight[file_path] = "missing"
    return filenames, preflight


_configure_logging()


class ProcessBatchRequest(BaseModel):
    manifest: dict[str, str]


@asynccontextmanager
async def lifespan(_: FastAPI):
    logger.info("Local backend starting on 8003")
    yield
    logger.info("Local backend shutting down")


# Initialize FastAPI
app = FastAPI(
    title="PR Metadata Bridge API",
    description="Microservice for automated EXIF metadata injection via OCR",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS Middleware (Permissive for local Flutter Desktop client)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  
    allow_credentials=True,
    allow_methods=["*"],  
    allow_headers=["*"],  
)

@app.get("/")
async def root():
    return {"status": "healthy", "service": "pr-metadata-bridge"}


@app.get("/health")
async def health():
    """Lightweight liveness probe for the desktop client startup gate."""
    return {"status": "ok"}


@app.post("/process-batch")
async def process_batch(payload: ProcessBatchRequest):
    """
    Receives a JSON manifest mapping file paths to VIP names and injects
    metadata in-place into each existing file after host-side path resolution.
    """
    filenames, preflight = _summarize_manifest(payload.manifest)
    logger.info(
        "/process-batch received: count=%s, filenames=%s",
        len(filenames),
        filenames,
    )
    try:
        processed_count = process_manifest_in_place(payload.manifest)
    except Exception:
        logger.exception("Unhandled exception while processing batch")
        raise

    for manifest_path, status in preflight.items():
        if status == "ready":
            logger.info("Batch completion: %s -> success", manifest_path)
        else:
            logger.info("Batch completion: %s -> failure (%s)", manifest_path, status)

    logger.info(
        "/process-batch completed: status=success, processed_count=%s, attempted=%s",
        processed_count,
        len(payload.manifest),
    )
    return {"status": "success", "processed_count": processed_count}

@app.post("/scan-badge")
async def scan_badge(file: UploadFile = File(...)):
    """
    Receives a single image file from Flutter, sends it to the OCR proxy,
    and returns the extracted VIP name.
    """
    img_bytes = await file.read()
    logger.info(
        "/scan-badge received: filename=%s, file_size_bytes=%s",
        file.filename,
        len(img_bytes),
    )

    proxy_url = os.getenv("PROXY_URL", "").strip()
    api_key = os.getenv("PROXY_API_KEY", "").strip()
    if not proxy_url or not api_key:
        logger.info("/scan-badge aborted: proxy config missing")
        return {"status": "error", "message": "Proxy offline"}

    try:
        headers = {"X-API-Key": os.getenv("PROXY_API_KEY", "").strip()}
        masked_headers: dict[str, Any] = {
            "X-API-Key": _mask_api_key(headers["X-API-Key"])
        }
        logger.info(
            "Before proxy call: url=%s, headers=%s",
            proxy_url,
            masked_headers,
        )
        response = requests.post(
            proxy_url,
            files={"file": (file.filename or "badge-crop.jpg", img_bytes, "image/jpeg")},
            headers=headers,
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        logger.info(
            "Proxy response: status_code=%s, body=%s",
            response.status_code,
            response.text,
        )
        response.raise_for_status()
        payload = response.json()

        if payload.get("status") != "success":
            return {"status": "error", "message": "Proxy offline"}

        clean_text = " ".join(str(payload.get("text", "")).split())
        logger.info("Scan completed: extracted_text=%s", clean_text)
        return {"status": "success", "filename": file.filename, "extracted_text": clean_text}
    except requests.exceptions.RequestException:
        logger.exception("Request exception during /scan-badge")
        return {"status": "error", "message": "Proxy offline"}
    except ValueError:
        logger.exception("JSON parse exception during /scan-badge")
        return {"status": "error", "message": "Proxy offline"}
    except Exception:
        logger.exception("Unhandled exception during /scan-badge")
        return {"status": "error", "message": "Proxy offline"}


if __name__ == "__main__":
    multiprocessing.freeze_support()
    if sys.stdout is None:
        sys.stdout = open(os.devnull, 'w')
    if sys.stderr is None:
        sys.stderr = open(os.devnull, 'w')

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=8003,
        log_config=None,
        access_log=False,
    )