#!/usr/bin/env python3
"""
Producer Script for Kafka Claims Processing Pipeline
Publishes JSON messages to the claims.incoming topic
"""

import json
import logging
import argparse
import uuid
from kafka import KafkaProducer
from kafka.errors import KafkaError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def create_producer(bootstrap_servers):
    """Create and return a Kafka producer instance."""
    try:
        producer = KafkaProducer(
            bootstrap_servers=bootstrap_servers,
            value_serializer=lambda v: json.dumps(v).encode('utf-8'),
            acks='all',
            retries=3
        )
        logger.info(f"Producer created successfully, connecting to {bootstrap_servers}")
        return producer
    except Exception as e:
        logger.error(f"Failed to create producer: {e}")
        raise


def send_message(producer, topic, message):
    """
    Send a message to a Kafka topic.
    
    Args:
        producer: KafkaProducer instance
        topic: Target topic name
        message: Message payload (dict)
    
    Returns:
        bool: True if successful, False otherwise
    """
    try:
        future = producer.send(topic, value=message)
        record_metadata = future.get(timeout=10)
        
        logger.info(f"Message sent to topic '{topic}' at partition {record_metadata.partition}, offset {record_metadata.offset}")
        logger.info(f"Message payload: {json.dumps(message)}")
        return True
        
    except KafkaError as e:
        logger.error(f"Failed to send message to Kafka: {e}")
        return False
    except Exception as e:
        logger.error(f"Unexpected error while sending message: {e}")
        return False


def generate_claim_message(document_id=None, test_fraud=False):
    """
    Generate a sample claim document message.
    
    Args:
        document_id: Optional document ID (generates UUID if not provided)
        test_fraud: If True, message will trigger fraud detection path
    
    Returns:
        dict: Claim message payload
    """
    if document_id is None:
        document_id = str(uuid.uuid4())
    
    message = {
        "documentId": document_id,
        "claimType": "insurance_claim",
        "claimAmount": 10000.00,
        "claimDate": "2024-05-14",
        "claimDescription": "Test claim for document processing pipeline",
        "testFraud": test_fraud,
        "claimStatus": "received"
    }
    
    return message


def main():
    """Main entry point for the producer script."""
    parser = argparse.ArgumentParser(
        description='Kafka Producer for Claims Processing Pipeline'
    )
    parser.add_argument(
        '--bootstrap-servers',
        default='localhost:9093',
        help='Kafka bootstrap server address (default: localhost:9093)'
    )
    parser.add_argument(
        '--topic',
        default='claims.incoming',
        help='Target Kafka topic (default: claims.incoming)'
    )
    parser.add_argument(
        '--count',
        type=int,
        default=1,
        help='Number of messages to send (default: 1)'
    )
    parser.add_argument(
        '--document-id',
        help='Specific document ID to use (generates UUID if not provided)'
    )
    parser.add_argument(
        '--test-fraud',
        action='store_true',
        help='Send message that will trigger fraud detection'
    )
    parser.add_argument(
        '--repeat-id',
        help='Send the same document ID twice to test idempotency'
    )
    
    args = parser.parse_args()
    
    try:
        # Create producer
        producer = create_producer(args.bootstrap_servers)
        
        # Handle repeat ID test case
        if args.repeat_id:
            logger.info(f"Testing idempotency with document ID: {args.repeat_id}")
            message = generate_claim_message(document_id=args.repeat_id, test_fraud=args.test_fraud)
            
            logger.info("Sending message 1 (first occurrence)...")
            send_message(producer, args.topic, message)
            
            logger.info("Waiting 2 seconds before sending duplicate...")
            import time
            time.sleep(2)
            
            logger.info("Sending message 2 (duplicate - should test idempotency)...")
            send_message(producer, args.topic, message)
        else:
            # Send regular messages
            for i in range(args.count):
                doc_id = args.document_id if args.document_id else None
                message = generate_claim_message(document_id=doc_id, test_fraud=args.test_fraud)
                
                logger.info(f"Sending message {i+1}/{args.count}")
                send_message(producer, args.topic, message)
        
        # Flush remaining messages
        producer.flush()
        logger.info("All messages sent successfully!")
        
    except KeyboardInterrupt:
        logger.info("Producer interrupted by user")
    except Exception as e:
        logger.error(f"Fatal error in producer: {e}")
        return 1
    finally:
        if 'producer' in locals():
            producer.close()
    
    return 0


if __name__ == '__main__':
    exit(main())
