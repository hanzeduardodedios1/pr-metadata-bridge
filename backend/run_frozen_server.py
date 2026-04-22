"""
Entry point for the PyInstaller one-file Windows build.

Uvicorn is started programmatically so the frozen app listens on 127.0.0.1:8001
with no separate console process (build with windowed=True / --windowed).

Import `app` at module scope so PyInstaller follows FastAPI, requests, and ExifTool
dependencies. A string factory like ``\"app.main:app\"`` is not analyzed.
"""
from __future__ import annotations

import multiprocessing
import os

import uvicorn

# Application object — pulls in FastAPI, requests, PyExifTool, etc.
from app.main import app as fastapi_app


def _configure_ssl_cert_bundle() -> None:
    """Ensure HTTPS clients can find CA certs inside a frozen bundle."""
    try:
        import certifi
    except ImportError:
        return
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())
    os.environ.setdefault("REQUESTS_CA_BUNDLE", certifi.where())


def main() -> None:
    _configure_ssl_cert_bundle()

    uvicorn.run(
        fastapi_app,
        host="127.0.0.1",
        port=8001,
        reload=False,
        access_log=True,
    )


if __name__ == "__main__":
    multiprocessing.freeze_support()
    main()
