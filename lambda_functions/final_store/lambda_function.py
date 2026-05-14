import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError
from kafka import KafkaProducer

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
AWS_ENDPOINT_URL = os.getenv('DYNAMODB_ENDPOINT_URL', 'http://localhost:4566')
AWS_REGION = os.getenv('AWS_REGION', 'us-east-1')
KAFKA_BOOTSTRAP_SERVERS = os.getenv('KAFKA_BOOTSTRAP_SERVERS', 'host.docker.internal:9093')
KAFKA_PROCESSED_TOPIC = os.getenv('KAFKA_PROCESSED_TOPIC', 'claims.processed')

dynamodb = boto3.resource(
    'dynamodb',
    endpoint_url=AWS_ENDPOINT_URL,
    region_name=AWS_REGION,
    aws_access_key_id='test',
    aws_secret_access_key='test'
)

_kafka_producer = None


def get_kafka_producer():
    global _kafka_producer

    if _kafka_producer is None:
        _kafka_producer = KafkaProducer(
            bootstrap_servers=KAFKA_BOOTSTRAP_SERVERS,
            value_serializer=lambda value: json.dumps(value).encode('utf-8'),
            key_serializer=lambda value: value.encode('utf-8') if value is not None else None,
            acks='all',
            retries=3,
        )

    return _kafka_producer


def extract_value(event, key, default=None):
    if key in event:
        return event.get(key, default)

    virus_result = event.get('virusResult', {}) or {}
    ocr_result = event.get('ocrResult', {}) or {}

    if key == 'scanStatus':
        return virus_result.get('scanStatus', default)
    if key == 'scanDetails':
        return virus_result.get('scanDetails', default)
    if key == 'extractedText':
        return ocr_result.get('extractedText', default)
    if key == 'confidence':
        return ocr_result.get('confidence', default)

    return default


def publish_completion_event(payload):
    producer = get_kafka_producer()
    completion_message = {
        'documentId': payload['documentId'],
        'status': payload['status'],
        'scanStatus': payload.get('scanStatus', 'clean'),
        'processedAt': datetime.now(timezone.utc).isoformat(),
    }

    future = producer.send(
        KAFKA_PROCESSED_TOPIC,
        key=payload['documentId'],
        value=completion_message,
    )
    future.get(timeout=10)
    producer.flush()
    logger.info(
        "Published completion event to Kafka topic '%s': %s",
        KAFKA_PROCESSED_TOPIC,
        json.dumps(completion_message),
    )


def lambda_handler(event, context):
    """
    FinalStore Lambda function.
    Writes the processed document status to DynamoDB with idempotency.
    Uses ConditionExpression to prevent duplicate records.
    """
    try:
        logger.info(f"FinalStore Lambda invoked with event: {json.dumps(event)}")
        
        # Extract document ID
        document_id = event.get('documentId', 'unknown')
        
        # Determine processing status based on whether it went through human review
        # This is simplified - in a real scenario, you'd have more complex logic
        status = event.get('processingStatus', 'processed')
        
        # Get the claims table
        table = dynamodb.Table('claims')
        
        # Prepare the item to write
        item = {
            'documentId': document_id,
            'status': status,
            'scanStatus': extract_value(event, 'scanStatus', 'clean'),
            'extractedText': extract_value(event, 'extractedText', ''),
            'timestamp': str(getattr(context, 'aws_request_id', datetime.now(timezone.utc).isoformat())),
            'executionArn': event.get('executionArn', 'unknown')
        }
        
        # Write to DynamoDB with conditional write (idempotency)
        try:
            response = table.put_item(
                Item=item,
                ConditionExpression='attribute_not_exists(documentId)'
            )
            logger.info(f"Successfully wrote to DynamoDB: {json.dumps(item)}")

            publish_completion_event(item)
            
            result = {
                "documentId": document_id,
                "status": "success",
                "message": "Document processed and stored successfully",
                "dynamodbWriteSuccess": True
            }
            
            return result
            
        except ClientError as e:
            if e.response['Error']['Code'] == 'ConditionalCheckFailedException':
                logger.warning(f"Document {document_id} already exists in DynamoDB. Idempotency check passed.")
                result = {
                    "documentId": document_id,
                    "status": "duplicate",
                    "message": "Document already processed (idempotency)",
                    "dynamodbWriteSuccess": False,
                    "isDuplicate": True
                }
                return result
            else:
                raise
    
    except Exception as e:
        logger.error(f"Error in FinalStore: {str(e)}")
        raise
