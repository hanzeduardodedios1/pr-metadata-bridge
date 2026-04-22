# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec: one-file, no-console Windows executable for the FastAPI backend.

Build from the backend directory:
  pyinstaller pr-metadata-bridge.spec

Optional: ship ExifTool's exiftool.exe next to the built EXE, or add a Tree/add_binary
for it — PyExifTool shells out to that binary; it is not embedded in the wheel.
"""
from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files

block_cipher = None
spec_dir = Path(SPECPATH).resolve()

# CA bundle for HTTPS clients in a frozen app
datas = collect_data_files("certifi")

hiddenimports = [
    # Uvicorn (dynamic imports / workers)
    "uvicorn",
    "uvicorn.logging",
    "uvicorn.loops",
    "uvicorn.loops.auto",
    "uvicorn.loops.asyncio",
    "uvicorn.protocols",
    "uvicorn.protocols.http",
    "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl",
    "uvicorn.protocols.websockets",
    "uvicorn.protocols.websockets.auto",
    "uvicorn.lifespan",
    "uvicorn.lifespan.on",
    "uvicorn.lifespan.off",
    # HTTP stack
    "h11",
    # Starlette / FastAPI
    "multipart",
    "starlette.routing",
    "starlette.middleware",
    "starlette.middleware.cors",
    "starlette.exceptions",
    "starlette.responses",
    "starlette.background",
    "anyio._backends",
    "anyio._backends._asyncio",
    # Pydantic v2
    "pydantic",
    "pydantic.deprecated.decorator",
    "pydantic_core._pydantic_core",
    # PyExifTool (import name is exiftool)
    "exiftool",
]

a = Analysis(
    ["run_frozen_server.py"],
    pathex=[str(spec_dir)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="pr-metadata-bridge-api",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
