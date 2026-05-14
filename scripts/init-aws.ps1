# PowerShell Script to Initialize AWS Resources in LocalStack
# This is the Windows-compatible version of init-aws.sh

param(
    [string]$LocalStackEndpoint = "http://localhost:4566",
    [string]$Region = "us-east-1"
)

Write-Host "==========================================" -ForegroundColor Green
Write-Host "Initializing AWS Resources in LocalStack" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

# Function to wait for LocalStack
function Wait-LocalStack {
    Write-Host "Waiting for LocalStack to be healthy..." -ForegroundColor Yellow
    $maxAttempts = 30
    $attempt = 0
    
    while ($attempt -lt $maxAttempts) {
        try {
            $health = awslocal health 2>&1
            if ($health -match "running" -or $health -match "available") {
                Write-Host "LocalStack is healthy!" -ForegroundColor Green
                return $true
            }
        }
        catch {
            # LocalStack not ready yet
        }
        
        $attempt++
        Write-Host "Attempt $attempt/$maxAttempts - Waiting for LocalStack..."
        Start-Sleep -Seconds 2
    }
    
    Write-Host "ERROR: LocalStack failed to become healthy" -ForegroundColor Red
    return $false
}

# Function to create a Lambda function
function Deploy-Lambda {
    param(
        [string]$FunctionName,
        [string]$FunctionPath,
        [string]$Description,
        [switch]$IncludeKafka
    )
    
    Write-Host "Deploying Lambda: $FunctionName" -ForegroundColor Yellow
    
    $buildDir = Join-Path $env:TEMP ("lambda-build-{0}" -f ([guid]::NewGuid().ToString()))
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    
    try {
        Copy-Item -Path (Join-Path $FunctionPath "lambda_function.py") -Destination $buildDir -Force

        if ($IncludeKafka) {
            python -m pip install --quiet kafka-python==2.0.2 -t $buildDir | Out-Null
        }

        $zipPath = Join-Path $FunctionPath "function.zip"
        if (Test-Path $zipPath) {
            Remove-Item $zipPath -Force
        }

        Compress-Archive -Path (Join-Path $buildDir "*") -DestinationPath $zipPath -Force

        $environmentValue = "Variables={DYNAMODB_ENDPOINT_URL=http://localhost:4566,AWS_REGION=us-east-1,KAFKA_BOOTSTRAP_SERVERS=host.docker.internal:9093,KAFKA_PROCESSED_TOPIC=claims.processed}"
        
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        try {
            if ($FunctionName -eq "FinalStore") {
                $response = awslocal lambda create-function `
                    --function-name $FunctionName `
                    --runtime python3.11 `
                    --role arn:aws:iam::000000000000:role/lambda-role `
                    --handler lambda_function.lambda_handler `
                    --zip-file "fileb://$zipPath" `
                    --description $Description `
                    --timeout 60 `
                    --environment $environmentValue `
                    --region $Region 2>&1
            }
            else {
                $response = awslocal lambda create-function `
                    --function-name $FunctionName `
                    --runtime python3.11 `
                    --role arn:aws:iam::000000000000:role/lambda-role `
                    --handler lambda_function.lambda_handler `
                    --zip-file "fileb://$zipPath" `
                    --description $Description `
                    --timeout 60 `
                    --region $Region 2>&1
            }
            
            Write-Host "  ✓ Lambda function $FunctionName created" -ForegroundColor Green
        }
        catch {
            # Try to update if function already exists
            $response = awslocal lambda update-function-code `
                --function-name $FunctionName `
                --zip-file "fileb://$zipPath" `
                --region $Region 2>&1
            
            Write-Host "  ✓ Lambda function $FunctionName updated" -ForegroundColor Green
        }
    }
    finally {
        # Clean up build artifacts
        if (Test-Path $buildDir) {
            Remove-Item $buildDir -Recurse -Force
        }
    }
}

# Main execution
try {
    # Wait for LocalStack
    if (-not (Wait-LocalStack)) {
        exit 1
    }
    
    # Create DynamoDB Table
    Write-Host ""
    Write-Host "Creating DynamoDB table: claims" -ForegroundColor Yellow
    
    try {
        awslocal dynamodb create-table `
            --table-name claims `
            --attribute-definitions AttributeName=documentId,AttributeType=S `
            --key-schema AttributeName=documentId,KeyType=HASH `
            --billing-mode PAY_PER_REQUEST `
            --region $Region | Out-Null
        
        Write-Host "  ✓ DynamoDB table created" -ForegroundColor Green
    }
    catch {
        Write-Host "  ⚠ Table may already exist" -ForegroundColor Yellow
    }
    
    # Create SNS Topic
    Write-Host "Creating SNS topic: claims-dead-letter-topic" -ForegroundColor Yellow
    
    $topicResponse = awslocal sns create-topic `
        --name claims-dead-letter-topic `
        --region $Region 2>&1
    
    $topicArn = $topicResponse | ConvertFrom-Json | Select-Object -ExpandProperty TopicArn
    Write-Host "  ✓ SNS Topic ARN: $topicArn" -ForegroundColor Green
    
    # Create Lambda Functions
    Write-Host ""
    Write-Host "Creating Lambda Functions..." -ForegroundColor Yellow
    
    # Get script directory
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $projectRoot = Split-Path -Parent $scriptDir
    
    # Deploy VirusScan Lambda
    Deploy-Lambda -FunctionName "VirusScan" `
        -FunctionPath "$projectRoot\lambda_functions\virus_scan" `
        -Description "Mock Virus Scan Lambda"
    
    # Deploy OCRExtract Lambda
    Deploy-Lambda -FunctionName "OCRExtract" `
        -FunctionPath "$projectRoot\lambda_functions\ocr_extract" `
        -Description "Mock OCR Extract Lambda"
    
    # Deploy FinalStore Lambda
    Deploy-Lambda -FunctionName "FinalStore" `
        -FunctionPath "$projectRoot\lambda_functions\final_store" `
        -Description "Mock Final Store Lambda" `
        -IncludeKafka
    
    # Create Step Function State Machine
    Write-Host ""
    Write-Host "Creating Step Function State Machine: ClaimProcessor" -ForegroundColor Yellow
    
    try {
        # Create state machine
        $stateMachinePath = ("$projectRoot\statemachine\claim-processor.asl.json") -replace '\\', '/'
        $stateResponse = awslocal stepfunctions create-state-machine `
            --name ClaimProcessor `
            --definition "file://$stateMachinePath" `
            --role-arn arn:aws:iam::000000000000:role/stepfunctions-role `
            --region $Region 2>&1
        
        Write-Host "  ✓ Step Function created" -ForegroundColor Green
    }
    catch {
        Write-Host "  ⚠ State machine may already exist" -ForegroundColor Yellow
    }
    
    # Display created resources
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "Resources created successfully!" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "DynamoDB Tables:" -ForegroundColor Cyan
    awslocal dynamodb list-tables --region $Region --query 'TableNames' --output table
    
    Write-Host ""
    Write-Host "Lambda Functions:" -ForegroundColor Cyan
    awslocal lambda list-functions --region $Region --query 'Functions[*].FunctionName' --output table
    
    Write-Host ""
    Write-Host "Step Functions:" -ForegroundColor Cyan
    awslocal stepfunctions list-state-machines --region $Region --output table
    
    Write-Host ""
    Write-Host "SNS Topics:" -ForegroundColor Cyan
    awslocal sns list-topics --region $Region --output table
    
    Write-Host ""
    Write-Host "Initialization Complete!" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
