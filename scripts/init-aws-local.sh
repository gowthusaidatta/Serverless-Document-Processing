#!/bin/bash

set -e

LOCALSTACK_CONTAINER=serverless-localstack

echo "=========================================="
echo "Initializing AWS Resources inside LocalStack (via docker exec)"
echo "=========================================="

# Wait for LocalStack to be ready inside container
echo "Waiting for LocalStack to be ready inside container..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if docker exec "$LOCALSTACK_CONTAINER" sh -c "curl -sS http://localhost:4566/_localstack/health | grep 'stepfunctions' >/dev/null 2>&1" ; then
        echo "LocalStack inside container is healthy!"
        break
    fi
    attempt=$((attempt + 1))
    echo "Attempt $attempt/$max_attempts - Waiting for LocalStack..."
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo "ERROR: LocalStack inside container failed to become healthy"
    exit 1
fi

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)

echo "Creating DynamoDB table: claims"
docker exec "$LOCALSTACK_CONTAINER" awslocal dynamodb create-table \
    --table-name claims \
    --attribute-definitions AttributeName=documentId,AttributeType=S \
    --key-schema AttributeName=documentId,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST --region us-east-1 || echo "Table may already exist"

echo "Creating SNS topic: claims-dead-letter-topic"
TOPIC_ARN=$(docker exec "$LOCALSTACK_CONTAINER" awslocal sns create-topic --name claims-dead-letter-topic --region us-east-1 --query 'TopicArn' --output text)
echo "SNS Topic ARN: $TOPIC_ARN"

echo "Packaging and deploying lambda functions"
deploy_lambda_local() {
    fn_name=$1
    fn_path="$PROJECT_ROOT/lambda_functions/$2"
    fn_path_win=$(wslpath -w "$fn_path")

    echo "Packaging $fn_name from $fn_path"
    zip_path="$fn_path/function.zip"
    zip_path_win=$(wslpath -w "$zip_path")
    /mnt/c/Windows/py.exe -3 -c "import zipfile, pathlib; fn_path = pathlib.Path(r'$fn_path_win'); zip_path = pathlib.Path(r'$zip_path_win'); archive = zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED); archive.write(fn_path / 'lambda_function.py', arcname='lambda_function.py'); archive.close()"

    # Copy zip into container
    docker cp "$zip_path" "$LOCALSTACK_CONTAINER":/tmp/"$fn_name".zip

    echo "Creating/updating lambda $fn_name"
    docker exec "$LOCALSTACK_CONTAINER" awslocal lambda create-function \
        --function-name "$fn_name" \
        --runtime python3.11 \
        --role arn:aws:iam::000000000000:role/lambda-role \
        --handler lambda_function.lambda_handler \
        --zip-file fileb:///tmp/"$fn_name".zip \
        --description "Mock $fn_name Lambda" --timeout 60 --region us-east-1 || \
    docker exec "$LOCALSTACK_CONTAINER" awslocal lambda update-function-code --function-name "$fn_name" --zip-file fileb:///tmp/"$fn_name".zip --region us-east-1

    # cleanup copied zip
    docker exec "$LOCALSTACK_CONTAINER" rm -f /tmp/"$fn_name".zip || true
    rm -f "$zip_path"
}

deploy_lambda_local "VirusScan" "virus_scan"
deploy_lambda_local "OCRExtract" "ocr_extract"
deploy_lambda_local "FinalStore" "final_store"

echo "Creating Step Function state machine: ClaimProcessor"
docker cp "$PROJECT_ROOT/statemachine/claim-processor.asl.json" "$LOCALSTACK_CONTAINER":/tmp/claim-processor.asl.json
docker exec "$LOCALSTACK_CONTAINER" awslocal stepfunctions create-state-machine --name ClaimProcessor --definition file:///tmp/claim-processor.asl.json --role-arn arn:aws:iam::000000000000:role/stepfunctions-role --region us-east-1 2>/dev/null || echo "State machine may already exist"

echo "Listing resources"
docker exec "$LOCALSTACK_CONTAINER" awslocal dynamodb list-tables --region us-east-1
docker exec "$LOCALSTACK_CONTAINER" awslocal lambda list-functions --region us-east-1 --query 'Functions[*].FunctionName' --output table
docker exec "$LOCALSTACK_CONTAINER" awslocal stepfunctions list-state-machines --region us-east-1
docker exec "$LOCALSTACK_CONTAINER" awslocal sns list-topics --region us-east-1

echo "Initialization complete"
