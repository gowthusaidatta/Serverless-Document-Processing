#!/usr/bin/env python3
"""
Monitoring and Reporting Script for Claims Processing Pipeline
Generates performance reports based on Step Function execution histories
"""

import json
import logging
import argparse
from datetime import datetime, timedelta
from typing import List, Dict, Optional
import boto3
from botocore.exceptions import ClientError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


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


def get_executions(client, state_machine_arn, max_results=10):
    """
    Get recent executions of the state machine.
    
    Args:
        client: Step Functions client
        state_machine_arn: ARN of the state machine
        max_results: Maximum number of executions to retrieve
    
    Returns:
        List[Dict]: List of execution summaries
    """
    try:
        response = client.list_executions(
            stateMachineArn=state_machine_arn,
            maxResults=max_results,
            statusFilter='SUCCEEDED'
        )
        
        executions = response.get('executions', [])
        logger.info(f"Retrieved {len(executions)} executions")
        return executions
        
    except ClientError as e:
        logger.error(f"Failed to list executions: {e}")
        return []


def get_execution_history(client, execution_arn):
    """
    Get the detailed execution history for an execution.
    
    Args:
        client: Step Functions client
        execution_arn: ARN of the execution
    
    Returns:
        List[Dict]: List of history events
    """
    try:
        response = client.get_execution_history(executionArn=execution_arn)
        events = response.get('events', [])
        logger.debug(f"Retrieved {len(events)} history events for execution {execution_arn}")
        return events
        
    except ClientError as e:
        logger.error(f"Failed to get execution history: {e}")
        return []


def parse_state_latencies(events) -> Dict[str, Optional[int]]:
    """
    Parse execution history events to calculate state latencies.
    
    Args:
        events: List of history events
    
    Returns:
        Dict[str, int]: Dictionary mapping state names to latency in milliseconds
    """
    latencies = {}
    state_starts = {}
    
    # Target states to measure
    target_states = ['VirusScan', 'OCRExtract', 'FinalStore']
    
    for event in events:
        event_type = event.get('type')
        details = event.get('stateEnteredEventDetails', {})
        state_name = details.get('name')
        
        # Record state entry
        if event_type == 'TaskStateEntered' and state_name in target_states:
            state_starts[state_name] = event.get('timestamp')
        
        # Record state exit/completion
        if event_type == 'TaskStateExited' and state_name in target_states:
            if state_name in state_starts:
                start_time = state_starts[state_name]
                end_time = event.get('timestamp')
                
                if start_time and end_time:
                    # Calculate duration in milliseconds
                    latency = int((end_time - start_time).total_seconds() * 1000)
                    latencies[state_name] = latency
                    logger.debug(f"State '{state_name}' latency: {latency}ms")
    
    # Add missing states with None
    for state in target_states:
        if state not in latencies:
            latencies[state] = None
    
    return latencies


def calculate_percentile(values: List[float], percentile: float) -> Optional[float]:
    """
    Calculate the nth percentile of a list of values.
    
    Args:
        values: List of numeric values
        percentile: Percentile to calculate (0-100)
    
    Returns:
        float or None: The percentile value, or None if values list is empty
    """
    if not values:
        return None
    
    sorted_values = sorted(values)
    index = (percentile / 100.0) * (len(sorted_values) - 1)
    
    # Linear interpolation
    lower_index = int(index)
    upper_index = min(lower_index + 1, len(sorted_values) - 1)
    fraction = index - lower_index
    
    if lower_index == upper_index:
        return sorted_values[lower_index]
    
    return sorted_values[lower_index] * (1 - fraction) + sorted_values[upper_index] * fraction


def generate_report(client, state_machine_arn, max_executions=10):
    """
    Generate a comprehensive performance report.
    
    Args:
        client: Step Functions client
        state_machine_arn: ARN of the state machine
        max_executions: Maximum number of executions to analyze
    
    Returns:
        Dict: Performance report structure
    """
    # Get executions
    executions = get_executions(client, state_machine_arn, max_executions)
    
    if not executions:
        logger.warning("No executions found")
        return {
            "report_summary": {
                "total_executions_analyzed": 0
            },
            "state_latency_ms": {
                "VirusScan": {"p50": None, "p95": None},
                "OCRExtract": {"p50": None, "p95": None},
                "FinalStore": {"p50": None, "p95": None}
            }
        }
    
    # Collect latencies for each state
    all_latencies = {
        'VirusScan': [],
        'OCRExtract': [],
        'FinalStore': []
    }
    
    # Process each execution
    for execution in executions:
        execution_arn = execution.get('executionArn')
        logger.info(f"Analyzing execution: {execution_arn}")
        
        # Get execution history
        history = get_execution_history(client, execution_arn)
        
        # Parse latencies
        latencies = parse_state_latencies(history)
        
        # Aggregate latencies
        for state, latency in latencies.items():
            if latency is not None:
                all_latencies[state].append(latency)
    
    # Calculate percentiles
    report = {
        "report_summary": {
            "total_executions_analyzed": len(executions)
        },
        "state_latency_ms": {}
    }
    
    for state in ['VirusScan', 'OCRExtract', 'FinalStore']:
        latencies = all_latencies[state]
        p50 = calculate_percentile(latencies, 50)
        p95 = calculate_percentile(latencies, 95)
        
        # Convert to int if not None
        p50 = int(p50) if p50 is not None else None
        p95 = int(p95) if p95 is not None else None
        
        report["state_latency_ms"][state] = {
            "p50": p50,
            "p95": p95
        }
        
        logger.info(f"State '{state}' - P50: {p50}ms, P95: {p95}ms (from {len(latencies)} samples)")
    
    return report


def main():
    """Main entry point for the reporting script."""
    parser = argparse.ArgumentParser(
        description='Generate performance report for Claims Processing Pipeline'
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
    parser.add_argument(
        '--max-executions',
        type=int,
        default=10,
        help='Maximum number of executions to analyze (default: 10)'
    )
    parser.add_argument(
        '--output-file',
        help='Write report to file instead of stdout'
    )
    
    args = parser.parse_args()
    
    try:
        # Create Step Functions client
        client = create_stepfunctions_client(args.endpoint_url)
        
        # Get state machine ARN
        state_machine_arn = get_state_machine_arn(client, args.state_machine_name)
        
        if not state_machine_arn:
            logger.error("Could not find state machine ARN")
            return 1
        
        # Generate report
        logger.info("Generating performance report...")
        report = generate_report(client, state_machine_arn, args.max_executions)
        
        # Output report
        report_json = json.dumps(report, indent=2)
        
        if args.output_file:
            with open(args.output_file, 'w') as f:
                f.write(report_json)
            logger.info(f"Report written to {args.output_file}")
        else:
            print(report_json)
        
        return 0
        
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        return 1


if __name__ == '__main__':
    exit(main())
