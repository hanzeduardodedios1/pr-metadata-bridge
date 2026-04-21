import os
from pathlib import Path, PureWindowsPath
from exiftool import ExifToolHelper

def _resolve_manifest_path(manifest_path: str) -> Path:
    """
    Resolve a manifest key (Windows or POSIX-style) to an absolute host path.
    """
    raw_value = (manifest_path or "").strip()
    if not raw_value:
        raise ValueError("Manifest path is empty")

    if os.name == "nt":
        # Windows host: normalize separators and keep drive/UNC semantics.
        candidate = Path(PureWindowsPath(raw_value))
    else:
        # POSIX host: accept both slash styles by converting backslashes first.
        candidate = Path(str(PureWindowsPath(raw_value)).replace("\\", "/"))

    if not candidate.is_absolute():
        # If a relative path somehow appears in the manifest, anchor it safely.
        candidate = (Path.cwd() / candidate).resolve()
    else:
        candidate = candidate.resolve()

    return candidate


def process_manifest_in_place(manifest: dict[str, str]) -> int:
    """
    Processes a map of absolute file paths -> VIP names and injects
    EXIF/IPTC/XMP tags directly into each original file on disk.

    Returns the number of files successfully processed.
    """
    print(f"🚀 Starting in-place processing for {len(manifest)} files.")
    processed_count = 0

    with ExifToolHelper() as et:
        for manifest_key, vip_name in manifest.items():
            try:
                resolved_path = _resolve_manifest_path(manifest_key)
            except (OSError, RuntimeError, ValueError) as exc:
                print(f"   ⚠️ Warning: invalid path '{manifest_key}': {exc}. Skipping.")
                continue

            if not resolved_path.is_file():
                print(f"   ⚠️ Warning: '{resolved_path}' does not exist. Skipping.")
                continue

            print(f"   -> Injecting '{vip_name}' into {resolved_path}")
            tags_to_inject = {
                "EXIF:ImageDescription": vip_name,
                "IPTC:Keywords": vip_name,
                "XMP:Subject": vip_name,
            }
            # ExifToolHelper uses argument lists under the hood, so paths with spaces are safe.
            et.set_tags(str(resolved_path), tags=tags_to_inject, params=["-overwrite_original"])
            processed_count += 1

    print("✅ Processing Complete.")
    return processed_count