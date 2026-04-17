import os
import json
from exiftool import ExifToolHelper

def process_event_directory(directory_path: str):
    """
    Reads the manifest.json provided by the Flutter frontend 
    and directly injects the specified tags.
    """
    print(f"🚀 Starting deterministic pipeline for directory: {directory_path}")
    
    # 1. Hunt down the manifest file, no matter how deep it is or if it has a .txt extension
    manifest_path = None
    for root, dirs, files in os.walk(directory_path):
        for file in files:
            if file.lower() in ["manifest.json", "manifest.json.txt"]:
                manifest_path = os.path.join(root, file)
                break
        if manifest_path:
            break
    
    if not manifest_path:
        print("❌ CRITICAL ERROR: No manifest.json found in the payload.")
        return

    # 2. Load the explicit instructions
    with open(manifest_path, "r") as f:
        tag_mapping = json.load(f)
        
    print(f"📜 Loaded manifest from {os.path.basename(manifest_path)} with {len(tag_mapping)} tagging instructions.")

    # 3. Build a quick lookup dictionary of all files in the extracted folder
    file_locator = {}
    for root, dirs, files in os.walk(directory_path):
        for file in files:
            file_locator[file] = os.path.join(root, file)

    # 4. Inject the tags exactly as instructed
    with ExifToolHelper() as et:
        for filename, vip_name in tag_mapping.items():
            if filename in file_locator:
                target_file = file_locator[filename]
                print(f"   -> Injecting '{vip_name}' into {filename}")
                
                tags_to_inject = {
                    "EXIF:ImageDescription": vip_name,
                    "IPTC:Keywords": vip_name,
                    "XMP:Subject": vip_name
                }
                et.set_tags(target_file, tags=tags_to_inject, params=["-overwrite_original"])
            else:
                print(f"   ⚠️ Warning: '{filename}' was in manifest but not found in folder.")

    print("✅ Processing Complete.")