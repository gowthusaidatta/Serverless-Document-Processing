@echo off
REM Windows Batch Script for Testing the Serverless Document Processing Pipeline
REM This provides convenient shortcuts for running tests and commands

setlocal enabledelayedexpansion

REM Colors for output (Windows 10+)
for /F %%A in ('echo prompt $H ^| cmd') do set "BS=%%A"

REM Get Minikube IP for Kafka
for /f "tokens=*" %%i in ('minikube ip 2^>nul') do set MINIKUBE_IP=%%i

if "%MINIKUBE_IP%"=="" (
    echo WARNING: Could not get Minikube IP. Minikube may not be running.
    echo.
    echo Available commands:
    echo   test-simple       - Send a simple claim
    echo   test-fraud        - Send a claim with fraud
    echo   test-idempotency  - Test duplicate handling
    echo   report            - Generate performance report
    echo   docker-status     - Check Docker status
    echo   kafka-status      - Check Kafka status
    echo   dynamodb-scan     - View DynamoDB records
    echo.
    echo Please start Minikube first:
    echo   minikube start --memory=4096 --cpus=2
    echo.
) else (
    echo Minikube IP: %MINIKUBE_IP%
)

echo.
echo Serverless Document Processing Pipeline - Test Commands
echo.

if "%1"=="" (
    echo Available commands:
    echo.
    echo Setup:
    echo   setup-windows.ps1          - Complete Windows setup (PowerShell)
    echo   init-aws.ps1               - Initialize AWS resources (PowerShell)
    echo.
    echo Testing:
    echo   run-consumer               - Start Kafka consumer
    echo   run-producer               - Send simple message
    echo   run-producer-fraud         - Send fraud message
    echo   run-producer-idempotency   - Test idempotency
    echo   generate-report            - View performance report
    echo.
    echo Monitoring:
    echo   check-dynamodb             - View DynamoDB records
    echo   check-kafka                - Check Kafka topics
    echo   check-status               - Check all services
    echo.
    echo Usage:
    echo   run.bat run-consumer
    echo   run.bat run-producer
    echo   run.bat generate-report
    echo.
) else if "%1"=="run-consumer" (
    echo Starting Kafka Consumer...
    echo Minikube IP: %MINIKUBE_IP%
    echo.
    python scripts\consumer.py --bootstrap-servers %MINIKUBE_IP%:9093
    
) else if "%1"=="run-producer" (
    echo Sending simple claim...
    echo Minikube IP: %MINIKUBE_IP%
    python scripts\producer.py --bootstrap-servers %MINIKUBE_IP%:9093
    
) else if "%1"=="run-producer-fraud" (
    echo Sending claim with fraud indicators...
    echo Minikube IP: %MINIKUBE_IP%
    python scripts\producer.py --bootstrap-servers %MINIKUBE_IP%:9093 --test-fraud
    
) else if "%1"=="run-producer-idempotency" (
    echo Testing idempotency with duplicate document ID...
    echo Minikube IP: %MINIKUBE_IP%
    python scripts\producer.py --bootstrap-servers %MINIKUBE_IP%:9093 --repeat-id "test-idempotency-doc-12345"
    
) else if "%1"=="generate-report" (
    echo Generating performance report...
    python scripts\generate_report.py
    
) else if "%1"=="check-dynamodb" (
    echo Scanning DynamoDB claims table...
    awslocal dynamodb scan --table-name claims --output table
    
) else if "%1"=="check-kafka" (
    echo Listing Kafka topics...
    kubectl get kafkatopic
    
) else if "%1"=="check-status" (
    echo.
    echo === Docker Status ===
    docker-compose ps
    echo.
    echo === Minikube Status ===
    minikube status
    echo.
    echo === Kubernetes Status ===
    kubectl cluster-info
    echo.
    echo === Kafka Status ===
    kubectl get kafka
    echo.
    echo === Kafka Topics ===
    kubectl get kafkatopic
    echo.
) else if "%1"=="help" (
    echo Help: Run test.bat with one of the following commands
    echo.
    echo run-consumer         - Start the Kafka consumer
    echo run-producer         - Send a test message
    echo run-producer-fraud   - Send a message that triggers fraud detection
    echo run-producer-idempotency - Test duplicate handling
    echo generate-report      - Generate performance report
    echo check-dynamodb       - View database records
    echo check-kafka          - Check Kafka topics
    echo check-status         - Check all services
    echo.
) else (
    echo Unknown command: %1
    echo Run "test.bat" with no arguments to see available commands
    echo.
)

endlocal
