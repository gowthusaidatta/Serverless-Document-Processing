import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Mock OCRExtract Lambda function.
    Simulates OCR text extraction from a document.
    Conditionally includes the word "fraud" based on the input payload.
    """
    try:
        logger.info(f"OCRExtract Lambda invoked with event: {json.dumps(event)}")
        
        # Check if the input indicates fraud testing
        should_contain_fraud = event.get("testFraud", False)
        
        # Simulate OCR extraction
        extracted_text = "This is extracted text from the document. "
        if should_contain_fraud:
            extracted_text += "This claim contains fraud keywords like fraud and suspicious patterns."
        else:
            extracted_text += "This is a legitimate claim request."
        
        result = {
            "documentId": event.get("documentId", "unknown"),
            "ocrResult": {
                "extractedText": extracted_text,
                "confidence": 0.95
            }
        }
        
        logger.info(f"OCRExtract result: {json.dumps(result)}")
        return result
    
    except Exception as e:
        logger.error(f"Error in OCRExtract: {str(e)}")
        raise
