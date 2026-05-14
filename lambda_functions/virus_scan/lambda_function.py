import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Mock VirusScan Lambda function.
    Simulates a virus scan on a document.
    """
    try:
        logger.info(f"VirusScan Lambda invoked with event: {json.dumps(event)}")
        
        # Simulate virus scan
        result = {
            "documentId": event.get("documentId", "unknown"),
            "scanStatus": "clean",
            "scanDetails": "No malware detected"
        }
        
        logger.info(f"VirusScan result: {json.dumps(result)}")
        return result
    
    except Exception as e:
        logger.error(f"Error in VirusScan: {str(e)}")
        raise
