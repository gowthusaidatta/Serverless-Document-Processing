#!/bin/bash

set -e

# Initialize AWS Resources in LocalStack
# This script sets up DynamoDB, SNS, Lambda functions, and Step Functions state machine

echo "=========================================="
echo "Initializing AWS Resources in LocalStack"
echo "=========================================="

# Wait for LocalStack to be healthy
echo "Waiting for LocalStack to be healthy..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if awslocal health > /dev/null 2>&1; then
        echo "LocalStack is healthy!"
        break
    fi
    attempt=$((attempt + 1))
    echo "Attempt $attempt/$max_attempts - Waiting for LocalStack..."
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo "ERROR: LocalStack failed to become healthy"
    exit 1
fi

# Create DynamoDB Table
echo ""
echo "Creating DynamoDB table: claims"
awslocal dynamodb create-table \
    --table-name claims \
    --attribute-definitions \
        AttributeName=documentId,AttributeType=S \
    --key-schema \
        AttributeName=documentId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region us-east-1 2>/dev/null || echo "Table may already exist"

# Create SNS Topic
echo "Creating SNS topic: claims-dead-letter-topic"
TOPIC_ARN=$(awslocal sns create-topic \
    --name claims-dead-letter-topic \
    --region us-east-1 \
    --query 'TopicArn' \
    --output text)
echo "SNS Topic ARN: $TOPIC_ARN"

# Create Lambda Functions
echo ""
echo "Creating Lambda Functions..."

# Helper function to package and deploy Lambda
deploy_lambda() {
    local function_name=$1
    local function_path=$2
    local description=$3
    local include_kafka=${4:-false}
    local build_dir
    local zip_path

    echo "Deploying Lambda: $function_name"

    build_dir=$(mktemp -d)
    zip_path="$function_path/function.zip"
    cp "$function_path/lambda_function.py" "$build_dir/"

    if [ "$include_kafka" = "true" ]; then
        python3 -m pip install --quiet kafka-python==2.0.2 -t "$build_dir"
    fi

    (cd "$build_dir" && zip -qr "$zip_path" .)

    if [ "$function_name" = "FinalStore" ]; then
        awslocal lambda create-function \
            --function-name "$function_name" \
            --runtime python3.11 \
            --role arn:aws:iam::000000000000:role/lambda-role \
            --handler lambda_function.lambda_handler \
            --zip-file fileb://"$zip_path" \
            --description "$description" \
            --timeout 60 \
            --environment "Variables={DYNAMODB_ENDPOINT_URL=http://localhost:4566,AWS_REGION=us-east-1,KAFKA_BOOTSTRAP_SERVERS=host.docker.internal:9093,KAFKA_PROCESSED_TOPIC=claims.processed}" \
            --region us-east-1 2>/dev/null || \
        awslocal lambda update-function-code \
            --function-name "$function_name" \
            --zip-file fileb://"$zip_path" \
            --region us-east-1 > /dev/null 2>&1
    else
        awslocal lambda create-function \
            --function-name "$function_name" \
            --runtime python3.11 \
            --role arn:aws:iam::000000000000:role/lambda-role \
            --handler lambda_function.lambda_handler \
            --zip-file fileb://"$zip_path" \
            --description "$description" \
            --timeout 60 \
            --region us-east-1 2>/dev/null || \
        awslocal lambda update-function-code \
            --function-name "$function_name" \
            --zip-file fileb://"$zip_path" \
            --region us-east-1 > /dev/null 2>&1
    fi

    rm -rf "$build_dir"
    rm -f "$zip_path"
}

# Get the script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Deploy VirusScan Lambda
deploy_lambda "VirusScan" "$PROJECT_ROOT/lambda_functions/virus_scan" "Mock Virus Scan Lambda"

# Deploy OCRExtract Lambda
deploy_lambda "OCRExtract" "$PROJECT_ROOT/lambda_functions/ocr_extract" "Mock OCR Extract Lambda"

# Deploy FinalStore Lambda
deploy_lambda "FinalStore" "$PROJECT_ROOT/lambda_functions/final_store" "Mock Final Store Lambda" "true"

# Create Step Function State Machine
echo ""
echo "Creating Step Function State Machine: ClaimProcessor"

awslocal stepfunctions create-state-machine \
    --name ClaimProcessor \
    --definition file://"$PROJECT_ROOT/statemachine/claim-processor.asl.json" \
    --role-arn arn:aws:iam::000000000000:role/stepfunctions-role \
    --region us-east-1 2>/dev/null || echo "State machine may already exist"

# List all resources created
echo ""
echo "=========================================="
echo "Resources created successfully!"
echo "=========================================="
echo ""
echo "DynamoDB Tables:"
awslocal dynamodb list-tables --region us-east-1

echo ""
echo "Lambda Functions:"
awslocal lambda list-functions --region us-east-1 --query 'Functions[*].FunctionName' --output table

echo ""
echo "Step Functions:"
awslocal stepfunctions list-state-machines --region us-east-1

echo ""
echo "SNS Topics:"
awslocal sns list-topics --region us-east-1

echo ""
echo "Initialization Complete!"
