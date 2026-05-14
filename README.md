# Serverless Document Processing Pipeline with AWS Step Functions and Kafka on Kubernetes

A production-grade event-driven document processing pipeline demonstrating orchestration with AWS Step Functions, message streaming with Apache Kafka on Kubernetes, and local development with LocalStack and Minikube.

## Project Overview

This project implements a resilient, scalable document processing system that handles:
- **Asynchronous orchestration** via AWS Step Functions
- **Event streaming** through Apache Kafka on Kubernetes
- **Serverless compute** with Lambda functions
- **Data persistence** with DynamoDB
- **Error handling** and dead-letter queues
- **Idempotency** at the database level
- **Performance monitoring** and reporting

## ⚡ Quick Start for Windows

If you're on **Windows**, use the automated setup script:

```powershell
# 1. Allow PowerShell scripts (one-time)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# 2. Run the complete setup
.\setup-windows.ps1

# 3. After setup, get your Minikube IP and start testing
$IP = minikube ip
python scripts/consumer.py --bootstrap-servers "${IP}:9093"

# In another PowerShell window:
$IP = minikube ip
python scripts/producer.py --bootstrap-servers "${IP}:9093"
```

**For detailed Windows setup**: See [WINDOWS_SETUP.md](WINDOWS_SETUP.md)

**Quick test commands**:
```powershell
test.bat run-producer
test.bat run-producer-fraud
test.bat run-producer-idempotency
test.bat generate-report
test.bat check-status
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Local Development Environment             │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────┐      ┌──────────────────────────┐     │
│  │   Kafka/Strimzi  │      │   LocalStack (Docker)    │     │
│  │   (Minikube)     │      │  - Lambda Functions      │     │
│  │                  │      │  - Step Functions        │     │
│  │ ┌──────────────┐ │      │  - DynamoDB             │     │
│  │ │claims.incoming│ │      │  - SNS Topics           │     │
│  │ └──────────────┘ │      │  - etc.                 │     │
│  │                  │      └──────────────────────────┘     │
│  │ ┌──────────────┐ │                                       │
│  │ │claims.processed│ │                                     │
│  │ └──────────────┘ │                                       │
│  └──────────────────┘                                       │
│         ▲                                                    │
│         │                                                    │
│    ┌────┴────┐                                              │
│    │ Consumer │─────────► Step Function: ClaimProcessor    │
│    └─────────┘                                              │
│         ▲                                                    │
│         │                                                    │
│    ┌────┴────┐                                              │
│    │ Producer │                                             │
│    └─────────┘                                              │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Monitoring: generate_report.py                       │   │
│  │  - Fetches execution histories                        │   │
│  │  - Calculates P50 and P95 latencies                   │   │
│  │  - Generates JSON report                              │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

### Required Software
- **Docker** and **Docker Compose** (for LocalStack)
- **Minikube** (for Kubernetes)
- **kubectl** (Kubernetes CLI)
- **Python 3.8+** with pip
- **awslocal** CLI (LocalStack AWS wrapper)
- **Strimzi Operator** (Kafka on Kubernetes)

### Installation

#### 1. Install Docker
```bash
# Windows: Use Docker Desktop
# macOS: brew install docker docker-compose
# Linux: Follow Docker documentation
```

#### 2. Install Minikube
```bash
# macOS
brew install minikube

# Windows (with Chocolatey)
choco install minikube

# Or download from: https://minikube.sigs.k8s.io/docs/start/
```

#### 3. Install kubectl
```bash
# macOS
brew install kubectl

# Windows (with Chocolatey)
choco install kubernetes-cli

# Or use Minikube's kubectl
minikube kubectl -- version
```

#### 4. Install Python Dependencies
```bash
pip install -r requirements.txt
```

## Quick Start

> **Windows Users**: See [WINDOWS_SETUP.md](WINDOWS_SETUP.md) for Windows-specific instructions and automated setup script `setup-windows.ps1`

### Phase 1: Environment Setup (macOS/Linux)

#### 1.1 Start LocalStack
```bash
cd path/to/project
docker-compose up -d

# Wait for health check
docker-compose logs -f localstack | grep "Ready to accept connections"
```

#### 1.2 Initialize AWS Resources
```bash
chmod +x scripts/init-aws.sh
./scripts/init-aws.sh
```

#### Windows Users
For Windows, use the PowerShell equivalent:
```powershell
# For AWS resources initialization
.\scripts\init-aws.ps1
```

#### 1.3 Start Minikube
```bash
minikube start --memory=4096 --cpus=2

# Enable ingress addon (optional)
minikube addons enable ingress
```

#### 1.4 Install Strimzi Operator
```bash
# Add Strimzi Helm repository
helm repo add strimzi https://strimzi.io/charts
helm repo update

# Install Strimzi operator
helm install strimzi-operator strimzi/strimzi-kafka-operator -n strimzi --create-namespace

# Wait for operator to be ready
kubectl wait --for=condition=Available --timeout=300s deployment/strimzi-cluster-operator -n strimzi
```

### Phase 2: Deploy Kafka Cluster and Topics

```bash
# Apply Kafka cluster configuration
kubectl apply -f k8s/kafka-cluster.yml

# Wait for Kafka broker to be ready (may take 1-2 minutes)
kubectl wait --for=condition=Ready pod -l strimzi.io/name=claims-kafka-kafka-0 -n default --timeout=300s

# Apply Kafka topics
kubectl apply -f k8s/kafka-topics.yml

# Verify topics are created
kubectl get kafkatopic
```

### Phase 3: Verify AWS Resources

```bash
# Check DynamoDB table
awslocal dynamodb describe-table --table-name claims

# Check Lambda functions
awslocal lambda list-functions --query 'Functions[*].FunctionName'

# Check Step Functions state machine
awslocal stepfunctions list-state-machines

# Check SNS topics
awslocal sns list-topics
```

### Phase 4: Run the Pipeline

#### Terminal 1: Start Consumer
```bash
# First, find Kafka service address
minikube service claims-kafka-kafka-bootstrap --url

# Set the bootstrap servers address and run consumer
python scripts/consumer.py --bootstrap-servers <KAFKA_ADDRESS>:9093
```

#### Terminal 2: Send Messages (Producer)
```bash
# Send a normal claim (no fraud)
python scripts/producer.py --bootstrap-servers localhost:9093

# Send a claim that triggers fraud detection
python scripts/producer.py --bootstrap-servers localhost:9093 --test-fraud

# Send duplicate for idempotency test
python scripts/producer.py --bootstrap-servers localhost:9093 --repeat-id "test-idempotency-doc-12345"
```

### Phase 5: Monitor Execution

```bash
# Check DynamoDB records
awslocal dynamodb scan --table-name claims

# Check SNS messages (if errors occurred)
awslocal sns list-subscriptions

# Generate performance report
python scripts/generate_report.py --max-executions 10
```

## Usage Examples

### Basic Claim Processing
```bash
python scripts/producer.py \
    --bootstrap-servers localhost:9093 \
    --topic claims.incoming \
    --count 1
```

### Testing Fraud Detection
```bash
python scripts/producer.py \
    --bootstrap-servers localhost:9093 \
    --test-fraud
```

### Testing Idempotency
```bash
python scripts/producer.py \
    --bootstrap-servers localhost:9093 \
    --repeat-id "unique-document-id"
```

### Generating Performance Report
```bash
python scripts/generate_report.py \
    --endpoint-url http://localhost:4566 \
    --max-executions 10 \
    --output-file report.json
```

## Step Function State Machine

The ClaimProcessor state machine follows this workflow:

1. **VirusScan** (Task)
   - Simulates antivirus scanning
   - Retry policy: 3 attempts with exponential backoff

2. **OCRExtract** (Task)
   - Extracts text from documents
   - Conditionally includes "fraud" keyword for testing
   - Retry policy: 3 attempts with exponential backoff

3. **FraudDetection** (Choice)
   - Examines extracted text for fraud indicators
   - Routes to HumanReviewQueue if fraud detected
   - Routes directly to FinalStore otherwise

4. **HumanReviewQueue** (Wait)
   - Simulates manual review process
   - Waits for 5 seconds

5. **FinalStore** (Task)
   - Writes results to DynamoDB
   - Uses conditional write for idempotency
   - Publishes confirmation to SNS

6. **CatchAllFailures** (Task)
   - Global error handler
   - Publishes error details to SNS dead-letter topic

## Key Features

### Idempotency
The FinalStore Lambda uses DynamoDB's `ConditionExpression` to implement exactly-once processing:

```python
response = table.put_item(
    Item=item,
    ConditionExpression='attribute_not_exists(documentId)'
)
```

This ensures duplicate messages produce only one database record.

### Retry Policies
Both VirusScan and OCRExtract implement exponential backoff:
- MaxAttempts: 3
- IntervalSeconds: 2
- BackoffRate: 1.5

### Error Handling
A global Catch block handles all failures and publishes to an SNS dead-letter topic for monitoring and alerting.

### Performance Monitoring
The generate_report.py script calculates:
- P50 (median) latency per state
- P95 (95th percentile) latency per state
- Total number of executions analyzed

## File Structure

```
.
├── docker-compose.yml                 # LocalStack container configuration
├── k8s/
│   ├── kafka-cluster.yml              # Kafka cluster definition
│   └── kafka-topics.yml               # Kafka topics definition
├── lambda_functions/
│   ├── virus_scan/
│   │   └── lambda_function.py        # VirusScan function
│   ├── ocr_extract/
│   │   └── lambda_function.py        # OCRExtract function
│   └── final_store/
│       └── lambda_function.py        # FinalStore function
├── statemachine/
│   └── claim-processor.asl.json      # Step Functions state machine definition
├── scripts/
│   ├── init-aws.sh                   # AWS resource provisioning script
│   ├── producer.py                   # Kafka message producer
│   ├── consumer.py                   # Kafka consumer + Step Function trigger
│   └── generate_report.py            # Performance monitoring and reporting
├── submission.json                    # Test configuration for idempotency
├── .env.example                       # Environment variables template
└── README.md                          # This file
```

## Testing

### Unit Tests
Each Lambda function can be tested locally:

```bash
# Test VirusScan
python -c "
from lambda_functions.virus_scan.lambda_function import lambda_handler
result = lambda_handler({'documentId': 'test-123'}, None)
print(result)
"
```

### Integration Tests

1. **Fraud Detection Path**
```bash
python scripts/producer.py --bootstrap-servers localhost:9093 --test-fraud
# Verify execution goes through HumanReviewQueue
```

2. **Idempotency Test**
```bash
# Send same ID twice
python scripts/producer.py --bootstrap-servers localhost:9093 --repeat-id "test-id"
# Verify only one record in DynamoDB
awslocal dynamodb scan --table-name claims | grep test-id
```

3. **Error Handling**
```bash
# Modify a Lambda to fail, trigger execution, verify SNS message
```

## Troubleshooting

### LocalStack not healthy
```bash
# Check logs
docker-compose logs localstack

# Restart
docker-compose down
docker-compose up -d
```

### Kafka cluster not created
```bash
# Check Strimzi operator logs
kubectl logs -f deployment/strimzi-cluster-operator -n strimzi

# Verify Kafka custom resource
kubectl describe kafka claims-kafka
```

### Consumer can't find Kafka
```bash
# Get Kafka service endpoint
minikube service claims-kafka-kafka-bootstrap --url

# Use returned address in consumer
```

### Lambda invocation fails
```bash
# Verify Lambda exists and has correct ARN
awslocal lambda list-functions

# Check Lambda logs (may not be available in LocalStack)
awslocal logs describe-log-groups
```

## Cleanup

```bash
# Stop and remove Docker containers
docker-compose down

# Delete Minikube cluster
minikube delete

# Remove generated files
rm -rf .localstack/
```

## References

- [AWS Step Functions Documentation](https://docs.aws.amazon.com/step-functions/)
- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
- [Strimzi Documentation](https://strimzi.io/docs/)
- [LocalStack Documentation](https://docs.localstack.cloud/)
- [Minikube Documentation](https://minikube.sigs.k8s.io/docs/)

## License

This project is provided as-is for educational purposes.
