# PowerShell Testing Script for Serverless Document Processing Pipeline
# Provides convenient shortcuts for running tests and commands

param(
    [string]$Command = "",
    [string]$Bootstrap = ""
)

# Get Minikube IP if not provided
if ([string]::IsNullOrEmpty($Bootstrap)) {
    try {
        $MINIKUBE_IP = minikube ip 2>&1
        if ($MINIKUBE_IP) {
            $Bootstrap = "${MINIKUBE_IP}:9093"
        }
    }
    catch {
        Write-Host "WARNING: Could not get Minikube IP. Minikube may not be running." -ForegroundColor Yellow
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Serverless Document Processing Pipeline - Test Commands    ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\test.ps1 <command>" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Setup & Deployment:" -ForegroundColor Cyan
    Write-Host "    setup                   - Run complete Windows setup"
    Write-Host "    init-aws                - Initialize AWS resources"
    Write-Host ""
    Write-Host "  Producer (send messages):" -ForegroundColor Cyan
    Write-Host "    simple                  - Send a simple claim"
    Write-Host "    fraud                   - Send a claim with fraud"
    Write-Host "    idempotency             - Test duplicate handling"
    Write-Host ""
    Write-Host "  Consumer (listening):" -ForegroundColor Cyan
    Write-Host "    consumer                - Start listening to Kafka"
    Write-Host ""
    Write-Host "  Monitoring & Verification:" -ForegroundColor Cyan
    Write-Host "    report                  - Generate performance report"
    Write-Host "    dynamodb                - View DynamoDB records"
    Write-Host "    topics                  - List Kafka topics"
    Write-Host "    status                  - Check all services"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\test.ps1 setup"
    Write-Host "  .\test.ps1 consumer"
    Write-Host "  .\test.ps1 simple"
    Write-Host "  .\test.ps1 fraud"
    Write-Host "  .\test.ps1 report"
    Write-Host ""
}

function Run-Command {
    param([string]$Cmd, [string]$Args)
    
    Write-Host ""
    Write-Host "► Running: $Cmd $Args" -ForegroundColor Green
    Write-Host "" 
    Invoke-Expression "$Cmd $Args"
}

# Main command handler
switch ($Command.ToLower()) {
    "" {
        Show-Help
    }
    
    "setup" {
        Write-Host "Starting Windows setup..." -ForegroundColor Green
        & .\setup-windows.ps1
    }
    
    "init-aws" {
        Write-Host "Initializing AWS resources..." -ForegroundColor Green
        & .\scripts\init-aws.ps1
    }
    
    "consumer" {
        if ([string]::IsNullOrEmpty($Bootstrap)) {
            Write-Host "ERROR: Minikube IP not available. Please start Minikube first." -ForegroundColor Red
            exit 1
        }
        Run-Command "python" "scripts\consumer.py --bootstrap-servers $Bootstrap"
    }
    
    "simple" {
        if ([string]::IsNullOrEmpty($Bootstrap)) {
            Write-Host "ERROR: Minikube IP not available. Please start Minikube first." -ForegroundColor Red
            exit 1
        }
        Run-Command "python" "scripts\producer.py --bootstrap-servers $Bootstrap"
    }
    
    "fraud" {
        if ([string]::IsNullOrEmpty($Bootstrap)) {
            Write-Host "ERROR: Minikube IP not available. Please start Minikube first." -ForegroundColor Red
            exit 1
        }
        Run-Command "python" "scripts\producer.py --bootstrap-servers $Bootstrap --test-fraud"
    }
    
    "idempotency" {
        if ([string]::IsNullOrEmpty($Bootstrap)) {
            Write-Host "ERROR: Minikube IP not available. Please start Minikube first." -ForegroundColor Red
            exit 1
        }
        Run-Command "python" "scripts\producer.py --bootstrap-servers $Bootstrap --repeat-id 'test-idempotency-doc-12345'"
    }
    
    "report" {
        Run-Command "python" "scripts\generate_report.py"
    }
    
    "dynamodb" {
        Run-Command "awslocal" "dynamodb scan --table-name claims --output table"
    }
    
    "topics" {
        Run-Command "kubectl" "get kafkatopic"
    }
    
    "status" {
        Write-Host ""
        Write-Host "═ Docker Status ═" -ForegroundColor Cyan
        docker-compose ps
        
        Write-Host ""
        Write-Host "═ Minikube Status ═" -ForegroundColor Cyan
        minikube status 2>&1
        
        Write-Host ""
        Write-Host "═ Kubernetes Status ═" -ForegroundColor Cyan
        kubectl cluster-info 2>&1
        
        Write-Host ""
        Write-Host "═ Kafka Cluster ═" -ForegroundColor Cyan
        kubectl get kafka
        
        Write-Host ""
        Write-Host "═ Kafka Topics ═" -ForegroundColor Cyan
        kubectl get kafkatopic
        
        Write-Host ""
        Write-Host "═ LocalStack Health ═" -ForegroundColor Cyan
        awslocal health 2>&1
    }
    
    "help" {
        Show-Help
    }
    
    default {
        Write-Host "Unknown command: $Command" -ForegroundColor Red
        Write-Host "Run '.\test.ps1 help' to see available commands" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ""
