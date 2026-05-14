#!/usr/bin/env python3
"""
Consumer Script for Kafka Claims Processing Pipeline
Listens to claims.incoming topic and triggers Step Function executions
"""

import json
import logging
import argparse
import uuid
from datetime import datetime
from kafka import KafkaConsumer
from kafka.errors import KafkaError
import boto3
from botocore.exceptions import ClientError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


def create_consumer(bootstrap_servers, topic):
    """Create and return a Kafka consumer instance."""
    try:
        consumer = KafkaConsumer(
            topic,
            bootstrap_servers=bootstrap_servers,
            group_id='claims-processor-group',
            value_deserializer=lambda m: json.loads(m.decode('utf-8')),
            auto_offset_reset='earliest',
            enable_auto_commit=True,
            session_timeout_ms=30000
        )
        logger.info(f"Consumer created successfully, subscribed to '{topic}'")
        return consumer
    except Exception as e:
        logger.error(f"Failed to create consumer: {e}")
        raise


def create_stepfunctions_client(endpoint_url='http://localhost:4566'):
    """Create and return a Step Functions client."""
    try:
        client = boto3.client(
            'stepfunctions',
            endpoint_url=endpoint_url,
            region_name='us-east-1',
            aws_access_key_id='test',
            aws_secret_access_key='test'
        )
        logger.info(f"Step Functions client created, endpoint: {endpoint_url}")
        return client
    except Exception as e:
        logger.error(f"Failed to create Step Functions client: {e}")
        raise


def get_state_machine_arn(client, state_machine_name='ClaimProcessor'):
    """Get the ARN of the ClaimProcessor state machine."""
    try:
        response = client.list_state_machines()
        
        for sm in response.get('stateMachines', []):
            if sm.get('name') == state_machine_name:
                logger.info(f"Found state machine ARN: {sm.get('stateMachineArn')}")
                return sm.get('stateMachineArn')
        
        logger.error(f"State machine '{state_machine_name}' not found")
        return None
    except ClientError as e:
        logger.error(f"Failed to list state machines: {e}")
        return None


def trigger_step_function(client, state_machine_arn, message):
    """
    Trigger a Step Function execution with the given message.
    
    Args:
        client: Step Functions client
        state_machine_arn: ARN of the state machine
        message: Kafka message payload
    
    Returns:
        str: Execution ARN if successful, None otherwise
    """
    try:
        # Generate unique execution name
        document_id = message.get('documentId', str(uuid.uuid4()))
        execution_name = f"execution-{document_id}-{datetime.now().strftime('%Y%m%d%H%M%S')}"
        
        # Prepare input for state machine
        state_machine_input = json.dumps(message)
        
        # Start the execution
        response = client.start_execution(
            stateMachineArn=state_machine_arn,
            name=execution_name,
            input=state_machine_input
        )
        
        execution_arn = response.get('executionArn')
        logger.info(f"Successfully triggered Step Function execution: {execution_arn}")
        logger.info(f"Execution input: {state_machine_input}")
        
        return execution_arn
        
    except ClientError as e:
        logger.error(f"Failed to trigger Step Function: {e}")
        return None
    except Exception as e:
        logger.error(f"Unexpected error while triggering Step Function: {e}")
        return None


def process_messages(consumer, client, state_machine_arn):
    """
    Process messages from Kafka and trigger Step Function executions.
    
    Args:
        consumer: KafkaConsumer instance
        client: Step Functions client
        state_machine_arn: ARN of the ClaimProcessor state machine
    """
    try:
        logger.info("Starting message processing loop...")
        
        for message in consumer:
            try:
                payload = message.value
                logger.info(f"Received message from topic '{message.topic}': {json.dumps(payload)}")
                
                # Trigger Step Function execution
                execution_arn = trigger_step_function(client, state_machine_arn, payload)
                
                if execution_arn:
                    logger.info(f"Message processed successfully, execution ARN: {execution_arn}")
                else:
                    logger.error("Failed to trigger Step Function for message")
                    
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse message: {e}")
            except Exception as e:
                logger.error(f"Error processing message: {e}")
                
    except KeyboardInterrupt:
        logger.info("Consumer interrupted by user")
    except KafkaError as e:
        logger.error(f"Kafka error: {e}")
    finally:
        consumer.close()
        logger.info("Consumer closed")


def main():
    """Main entry point for the consumer script."""
    parser = argparse.ArgumentParser(
        description='Kafka Consumer for Claims Processing Pipeline'
    )
    parser.add_argument(
        '--bootstrap-servers',
        default='localhost:9093',
        help='Kafka bootstrap server address (default: localhost:9093)'
    )
    parser.add_argument(
        '--topic',
        default='claims.incoming',
        help='Kafka topic to consume from (default: claims.incoming)'
    )
    parser.add_argument(
        '--endpoint-url',
        default='http://localhost:4566',
        help='LocalStack endpoint URL (default: http://localhost:4566)'
    )
    parser.add_argument(
        '--state-machine-name',
        default='ClaimProcessor',
        help='Name of the Step Function state machine (default: ClaimProcessor)'
    )
    
    args = parser.parse_args()
    
    try:
        # Create Kafka consumer
        consumer = create_consumer(args.bootstrap_servers, args.topic)
        
        # Create Step Functions client
        client = create_stepfunctions_client(args.endpoint_url)
        
        # Get state machine ARN
        state_machine_arn = get_state_machine_arn(client, args.state_machine_name)
        
        if not state_machine_arn:
            logger.error("Could not find state machine ARN")
            return 1
        
        # Start processing messages
        process_messages(consumer, client, state_machine_arn)
        
    except Exception as e:
        logger.error(f"Fatal error in consumer: {e}")
        return 1
    
    return 0


if __name__ == '__main__':
    exit(main())
