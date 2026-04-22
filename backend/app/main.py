import multiprocessing

from pydantic import BaseModel
from fastapi import FastAPI, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
import uvicorn
from app.services.ocr_service import extract_text
from dotenv import load_dotenv
from app.services.exif_logic import process_manifest_in_place

load_dotenv()  # This forces FastAPI to read your .env file on startup


class ProcessBatchRequest(BaseModel):
    manifest: dict[str, str]

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
    processed_count = process_manifest_in_place(payload.manifest)
    return {"status": "success", "processed_count": processed_count}

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


if __name__ == "__main__":
    multiprocessing.freeze_support()
    uvicorn.run(app, host="127.0.0.1", port=8001)