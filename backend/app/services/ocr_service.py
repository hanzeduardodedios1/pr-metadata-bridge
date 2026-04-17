from google.cloud import vision

def extract_text(img_bytes: bytes) -> str:
    """
    Sends image bytes to Google Cloud Vision API and returns the extracted text.
    """
    try:
        # The client automatically looks for your environment variable credentials
        client = vision.ImageAnnotatorClient()
        image = vision.Image(content=img_bytes)
        
        response = client.text_detection(image=image)
        
        if response.error.message:
            raise Exception(response.error.message)
            
        annotations = response.text_annotations
        if annotations:
            # annotations[0] contains the fully aggregated text block
            return annotations[0].description.strip()
            
        return ""
    except Exception as e:
        print(f"OCR Error: {e}")
        return "ERROR_READING_TEXT"