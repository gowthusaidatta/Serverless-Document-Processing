# Complete Windows Setup Script for Serverless Document Processing Pipeline
# Run this script with: .\setup-windows.ps1

Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Serverless Document Processing Pipeline - Windows Setup  ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Set error action preference
$ErrorActionPreference = "Continue"

# Color functions
function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Write-Warning-Custom {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ $Message" -ForegroundColor Cyan
}

# Check prerequisites
Write-Host ""
Write-Host "═ Prerequisites Check ═" -ForegroundColor Magenta
Write-Host ""

$allPrereqsMet = $true

# Check Docker
Write-Info "Checking Docker..."
if (docker --version 2>&1 | Select-String -Pattern "version") {
    Write-Success "Docker installed"
}
else {
    Write-Error-Custom "Docker not found. Install from https://www.docker.com/products/docker-desktop"
    $allPrereqsMet = $false
}

# Check Docker running
Write-Info "Checking if Docker is running..."
if (docker ps 2>&1 | Select-String -Pattern "STATUS" -Quiet) {
    Write-Success "Docker is running"
}
else {
    Write-Warning-Custom "Docker is not running. Please start Docker Desktop and run this script again."
    $allPrereqsMet = $false
}

# Check Python
Write-Info "Checking Python..."
if (python --version 2>&1 | Select-String -Pattern "Python") {
    $pythonVersion = python --version 2>&1
    Write-Success "$pythonVersion"
}
else {
    Write-Error-Custom "Python not found. Install from https://www.python.org/"
    $allPrereqsMet = $false
}

# Check Minikube
Write-Info "Checking Minikube..."
if (minikube version 2>&1 | Select-String -Pattern "minikube") {
    Write-Success "Minikube installed"
}
else {
    Write-Warning-Custom "Minikube not found. Download from https://minikube.sigs.k8s.io/docs/start/"
    Write-Info "Without Minikube, you can only test LocalStack services (Lambda, DynamoDB, Step Functions)"
    # Not fatal, continue with LocalStack only
}

# Check kubectl
Write-Info "Checking kubectl..."
if (kubectl version --client 2>&1 | Select-String -Pattern "version") {
    Write-Success "kubectl installed"
}
else {
    Write-Warning-Custom "kubectl not found. It will be installed with Minikube."
}

# Check Helm
Write-Info "Checking Helm..."
if (helm version 2>&1 | Select-String -Pattern "version") {
    Write-Success "Helm installed"
}
else {
    Write-Warning-Custom "Helm not found. Download from https://helm.sh/docs/intro/install/"
}

# Check awslocal
Write-Info "Checking awslocal..."
if (awslocal --version 2>&1 | Select-String -Pattern "version") {
    Write-Success "awslocal installed"
}
else {
    Write-Warning-Custom "awslocal not found. Installing..."
    pip install awscli-local --quiet
    if ($?) {
        Write-Success "awslocal installed"
    }
    else {
        Write-Error-Custom "Failed to install awslocal"
        $allPrereqsMet = $false
    }
}

if (-not $allPrereqsMet) {
    Write-Error-Custom "Some prerequisites are missing. Please install them and run again."
    Write-Info "See WINDOWS_SETUP.md for detailed installation instructions."
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Success "All prerequisites are available!"

# Install Python dependencies
Write-Host ""
Write-Host "═ Installing Python Dependencies ═" -ForegroundColor Magenta
Write-Host ""

Write-Info "Installing packages from requirements.txt..."
pip install -r requirements.txt -q
if ($?) {
    Write-Success "Python dependencies installed"
}
else {
    Write-Error-Custom "Failed to install Python dependencies"
    exit 1
}

# Start LocalStack
Write-Host ""
Write-Host "═ Starting LocalStack (Docker) ═" -ForegroundColor Magenta
Write-Host ""

Write-Info "Starting LocalStack container..."
docker-compose up -d
Start-Sleep -Seconds 3

# Check LocalStack health
Write-Info "Waiting for LocalStack to be healthy..."
$maxAttempts = 30
$attempt = 0

while ($attempt -lt $maxAttempts) {
    try {
        $health = docker-compose logs localstack 2>&1 | Select-String -Pattern "Ready"
        if ($health) {
            Write-Success "LocalStack is ready"
            break
        }
    }
    catch {
        # Not ready yet
    }
    
    $attempt++
    if ($attempt -lt $maxAttempts) {
        Write-Host "  Waiting... ($attempt/$maxAttempts)" -ForegroundColor Gray
        Start-Sleep -Seconds 2
    }
}

if ($attempt -ge $maxAttempts) {
    Write-Warning-Custom "LocalStack took longer to start. It should be ready now."
}

# Verify LocalStack
Write-Info "Verifying LocalStack connectivity..."
try {
    $health = awslocal health 2>&1
    if ($health) {
        Write-Success "LocalStack is accessible"
    }
}
catch {
    Write-Warning-Custom "Could not verify LocalStack. Continuing anyway..."
}

# Initialize AWS resources
Write-Host ""
Write-Host "═ Initializing AWS Resources ═" -ForegroundColor Magenta
Write-Host ""

Write-Info "Running AWS resource provisioning script..."
& "$PSScriptRoot\scripts\init-aws.ps1"

if ($?) {
    Write-Success "AWS resources provisioned"
}
else {
    Write-Error-Custom "Failed to provision AWS resources"
    exit 1
}

# Start Minikube
Write-Host ""
Write-Host "═ Starting Minikube ═" -ForegroundColor Magenta
Write-Host ""

Write-Info "Starting Minikube cluster..."
minikube start --memory=4096 --cpus=2 --driver=docker 2>&1 | Out-Null

if ($?) {
    Write-Success "Minikube cluster started"
}
else {
    Write-Warning-Custom "Minikube failed to start. Some features may not work."
}

# Deploy Strimzi
Write-Host ""
Write-Host "═ Installing Strimzi Operator ═" -ForegroundColor Magenta
Write-Host ""

Write-Info "Adding Strimzi Helm repository..."
helm repo add strimzi https://strimzi.io/charts 2>&1 | Out-Null
helm repo update 2>&1 | Out-Null

Write-Info "Installing Strimzi operator..."
helm install strimzi-operator strimzi/strimzi-kafka-operator `
    --namespace strimzi `
    --create-namespace `
    --set watchAnyNamespace=true 2>&1 | Out-Null

Start-Sleep -Seconds 10

Write-Info "Waiting for Strimzi operator to be ready..."
kubectl wait --for=condition=Available --timeout=300s `
    deployment/strimzi-cluster-operator -n strimzi 2>&1 | Out-Null

if ($?) {
    Write-Success "Strimzi operator ready"
}
else {
    Write-Warning-Custom "Strimzi operator took longer to start"
}

# Deploy Kafka
Write-Host ""
Write-Host "═ Deploying Kafka Cluster and Topics ═" -ForegroundColor Magenta
Write-Host ""

Write-Info "Creating Kafka cluster..."
kubectl apply -f k8s/kafka-cluster.yml 2>&1 | Out-Null

Write-Info "Waiting for Kafka broker to be ready (this may take 1-2 minutes)..."
kubectl wait --for=condition=Ready pod `
    -l strimzi.io/name=claims-kafka-kafka-0 `
    --timeout=300s 2>&1 | Out-Null

if ($?) {
    Write-Success "Kafka cluster ready"
}
else {
    Write-Warning-Custom "Kafka cluster took longer to start"
}

Write-Info "Creating Kafka topics..."
kubectl apply -f k8s/kafka-topics.yml 2>&1 | Out-Null

Start-Sleep -Seconds 5
Write-Success "Kafka topics created"

# Final summary
Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║           Setup Complete! Ready to Test Pipeline           ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Get Minikube IP (for Kafka connection):" -ForegroundColor Yellow
Write-Host '   $IP = minikube ip; Write-Host "Minikube IP: $IP"'
Write-Host ""

Write-Host "2. In Terminal 1 - Start Consumer:" -ForegroundColor Yellow
Write-Host '   $IP = minikube ip; python scripts/consumer.py --bootstrap-servers "${IP}:9093"'
Write-Host ""

Write-Host "3. In Terminal 2 - Send Messages:" -ForegroundColor Yellow
Write-Host '   $IP = minikube ip'
Write-Host '   python scripts/producer.py --bootstrap-servers "${IP}:9093"'
Write-Host '   python scripts/producer.py --bootstrap-servers "${IP}:9093" --test-fraud'
Write-Host '   python scripts/producer.py --bootstrap-servers "${IP}:9093" --repeat-id "test-id"'
Write-Host ""

Write-Host "4. In Terminal 3 - Monitor Performance:" -ForegroundColor Yellow
Write-Host '   python scripts/generate_report.py'
Write-Host ""

Write-Host "Useful Commands:" -ForegroundColor Cyan
Write-Host "  Check Kafka topics:    kubectl get kafkatopic"
Write-Host "  Check DynamoDB records: awslocal dynamodb scan --table-name claims"
Write-Host "  View Minikube status:   minikube status"
Write-Host "  Stop everything:        docker-compose down; minikube delete"
Write-Host ""

Write-Host "Documentation:" -ForegroundColor Cyan
Write-Host "  Quick Start:        README.md"
Write-Host "  Detailed Setup:     WINDOWS_SETUP.md"
Write-Host "  Architecture:       ARCHITECTURE.md"
Write-Host "  Troubleshooting:    QUICK_REFERENCE.md"
Write-Host ""

Write-Success "Setup complete! You can now proceed with testing."
Write-Host ""
