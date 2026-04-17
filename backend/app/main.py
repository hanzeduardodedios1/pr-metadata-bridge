import os
import shutil
import zipfile
from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from app.services.exif_logic import process_event_directory
from app.services.ocr_service import extract_text
from dotenv import load_dotenv
load_dotenv()  # This forces FastAPI to read your .env file on startup
# Import our brains
from app.services.exif_logic import process_event_directory

# Initialize FastAPI
app = FastAPI(
    title="PR Metadata Bridge API",
    description="Microservice for automated EXIF metadata injection via OCR",
    version="0.1.0"
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
async def health_check():
    return {"status": "healthy", "service": "pr-metadata-bridge"}

@app.post("/process-batch")
async def process_batch_sync(file_archive: UploadFile = File(...)):
    """
    Receives a zip file, extracts it, runs the Exif logic, 
    and returns the tagged zip file.
    """
    print(f"📦 Received file: {file_archive.filename}")
    
    # 1. Setup temporary directories
    base_dir = os.path.dirname(os.path.dirname(__file__))
    temp_dir = os.path.join(base_dir, "temp_processing")
    extract_dir = os.path.join(temp_dir, "extracted")
    output_zip = os.path.join(temp_dir, "tagged_deliverables.zip")

    # Clean up previous runs if they exist
    if os.path.exists(temp_dir):
        shutil.rmtree(temp_dir)
    os.makedirs(extract_dir, exist_ok=True)

    # 2. Save the uploaded zip locally
    zip_path = os.path.join(temp_dir, file_archive.filename)
    with open(zip_path, "wb") as buffer:
        shutil.copyfileobj(file_archive.file, buffer)

    # 3. Extract the files
    print("🗜️ Extracting files...")
    with zipfile.ZipFile(zip_path, 'r') as zip_ref:
        zip_ref.extractall(extract_dir)

    # 4. Run the Core Logic!
    print("🧠 Running EXIF logic...")
    process_event_directory(extract_dir)

    # 5. Zip the processed files back up
    print("🤐 Re-zipping deliverables...")
    # shutil.make_archive creates the zip without needing the .zip extension in the target name
    shutil.make_archive(output_zip.replace('.zip', ''), 'zip', extract_dir)

    # 6. Return the file to the client
    print("🚀 Sending deliverables back to client.")
    return FileResponse(
        path=output_zip,
        filename="Tagged_Event_Photos.zip",
        media_type="application/zip"
    )

@app.post("/scan-badge")
async def scan_badge(file: UploadFile = File(...)):
    """
    Receives a single image file from Flutter, sends it to Google Vision,
    and returns the extracted VIP name.
    """
    print(f"🔍 Received badge for scanning: {file.filename}")
    
    # Read the file into memory
    img_bytes = await file.read()
    
    # Send to Google Cloud Vision
    text = extract_text(img_bytes)
    
    # Clean up the string (replace newlines with spaces for a cleaner EXIF tag)
    clean_text = " ".join(text.split())
    
    print(f"✅ Extracted Text: {clean_text}")
    
    return {
        "filename": file.filename,
        "extracted_text": clean_text
    }