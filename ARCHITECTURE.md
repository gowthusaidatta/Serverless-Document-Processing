# Architecture and Design Document

## System Overview

The Serverless Document Processing Pipeline is a production-grade, event-driven system designed to handle high-volume document processing with reliability, scalability, and fault tolerance. The system demonstrates enterprise-grade patterns for asynchronous workflows.

## Core Components

### 1. Message Ingestion Layer (Kafka on Kubernetes)

**Technology**: Apache Kafka with Strimzi operator on Minikube

**Purpose**: Provides a durable, ordered event log for document intake

**Key Features**:
- **Decoupling**: Producers and consumers are independent
- **Durability**: Messages persist even if processors are down
- **Ordering**: Messages maintain FIFO ordering per partition
- **Scalability**: Can be scaled to multiple brokers and partitions

**Topics**:
- `claims.incoming`: Receives new document intake events
- `claims.processed`: Publishes completion events

### 2. Orchestration Layer (AWS Step Functions)

**Technology**: AWS Step Functions with Amazon States Language (ASL)

**Purpose**: Orchestrates multi-step document processing workflows

**Workflow States**:
```
VirusScan
    ↓
OCRExtract
    ↓
FraudDetection (Choice)
    ├─→ fraud detected ─→ HumanReviewQueue
    │                          ↓
    └─→ no fraud ─────────────┘
                                ↓
                          FinalStore
                                ↓
                              End
                            (or Error)
                                ↓
                        CatchAllFailures
                          (SNS notification)
```

**Resilience Features**:
- **Retry Policy**: Automatic retries with exponential backoff
  - VirusScan & OCRExtract: 3 retries, 2s initial interval, 1.5x backoff
  - FinalStore: 2 retries with faster backoff
- **Error Handling**: Global Catch block routes failures to SNS dead-letter topic
- **Idempotency**: Handled at the database level

### 3. Processing Layer (Lambda Functions)

**Technology**: Python-based Lambda functions in LocalStack

**Functions**:

#### VirusScan Lambda
- **Input**: Document metadata and content
- **Logic**: Simulates antivirus scanning
- **Output**: Adds `scanStatus` and `scanDetails` fields
- **Retry**: Yes (3 attempts)

#### OCRExtract Lambda
- **Input**: Scanned document
- **Logic**: Simulates optical character recognition
- **Output**: Adds `ocrResult` with `extractedText` and `confidence`
- **Special**: Conditionally includes fraud keywords for testing
- **Retry**: Yes (3 attempts)

#### FinalStore Lambda
- **Input**: Complete processing context
- **Logic**: 
  - Writes to DynamoDB with idempotency
  - Detects and gracefully handles duplicates
- **Output**: Processing status and results
- **Idempotency**: Uses DynamoDB `ConditionExpression`

### 4. Data Layer (DynamoDB)

**Technology**: Amazon DynamoDB in LocalStack

**Table**: `claims`

**Schema**:
```
Primary Key (Partition Key): documentId (String)

Attributes:
- status (String): Final processing status
- scanStatus (String): Virus scan result
- extractedText (String): OCR output
- timestamp (String): Processing timestamp
- executionArn (String): Associated Step Function execution
```

**Idempotency Mechanism**:
- **ConditionExpression**: `attribute_not_exists(documentId)`
- **Behavior**: Write succeeds only if document ID doesn't exist
- **Duplicate Handling**: 
  - First occurrence: Item is created, execution succeeds
  - Subsequent occurrences: DynamoDB rejects with ConditionalCheckFailedException
  - Lambda catches exception and returns `duplicate` status
  - Step Function execution still marks as SUCCEEDED (catch handled the error)

### 5. Alerting Layer (SNS)

**Technology**: Amazon SNS in LocalStack

**Topic**: `claims-dead-letter-topic`

**Purpose**: Collects error notifications and alerts

**When Used**:
- Step Function execution encounters uncaught errors
- Global Catch block publishes error details
- Can be subscribed to for email, SMS, or webhook notifications

### 6. Monitoring Layer (Python Reporting)

**Technology**: Python script querying Step Functions API

**Metrics Collected**:
- P50 (median) latency per state
- P95 (95th percentile) latency per state
- Total executions analyzed
- Individual state durations

**Output**: JSON-formatted performance report

## Data Flow

### Normal Happy Path

```
1. Producer sends message to Kafka
   └─→ Topic: claims.incoming
       Document: {documentId, claimType, amount, testFraud, ...}

2. Consumer listens to claims.incoming
   └─→ On message received:
       - Parse message
       - Call Step Functions StartExecution API
       - Pass message as state machine input

3. Step Function executes ClaimProcessor state machine
   └─→ VirusScan → OCRExtract → FraudDetection → [HumanReviewQueue] → FinalStore → End

4. FinalStore Lambda
   └─→ Write to DynamoDB (documentId as key)
   └─→ Publish to claims.processed topic
   └─→ Return success

5. Monitoring script queries execution histories
   └─→ Parse event timings
   └─→ Calculate percentiles
   └─→ Generate JSON report
```

### Fraud Detection Path

If extracted text contains "fraud":
```
OCRExtract (returns text with "fraud") 
  → FraudDetection (detects "fraud" keyword)
  → HumanReviewQueue (Wait 5 seconds)
  → FinalStore (stores with fraud flag)
```

### Error Path

If any state fails after retries:
```
Failed State (exhausted retries)
  → Global Catch block (catches States.ALL)
  → CatchAllFailures (publishes to SNS)
  → Execution marks as SUCCEEDED (error was handled)
```

### Idempotency Path

If duplicate document ID is processed:
```
First execution:
  FinalStore → DynamoDB PutItem succeeds → Execution SUCCEEDED

Second execution (same documentId):
  FinalStore → DynamoDB PutItem fails (ConditionalCheckFailedException)
  → Lambda catches exception → Returns {status: "duplicate"}
  → Execution SUCCEEDED (gracefully handled)
  → DynamoDB still has only ONE record
```

## Key Design Patterns

### 1. Idempotency at Database Level

**Why**: Prevents duplicate processing of messages

**How**: 
- Use database-level constraints (`ConditionExpression`)
- Application layer catches rejection and returns gracefully
- More reliable than application-level deduplication

**Benefits**:
- Atomic operation (no race conditions)
- Works across multiple Lambda invocations
- Minimal performance overhead

### 2. Retry with Exponential Backoff

**Why**: Handles transient failures

**Configuration**:
- ErrorEquals: `["States.ALL"]` (catches all error types)
- MaxAttempts: 3 (tries up to 3 times)
- IntervalSeconds: 2 (initial wait)
- BackoffRate: 1.5 (multiply wait by 1.5 each retry)
  - Attempt 1: immediate
  - Attempt 2: wait 2s
  - Attempt 3: wait 3s
  - Attempt 4+: fail

### 3. Global Error Handling

**Why**: Ensures no errors go unnoticed

**How**:
- Top-level Catch block in Step Function
- Catches all error types
- Routes to notification system (SNS)

**Benefits**:
- Prevents silent failures
- Enables operational alerting
- Maintains audit trail

### 4. Event-Driven Architecture

**Why**: Decouples systems, enables scaling

**How**:
- Kafka acts as central event hub
- Producers and consumers are independent
- Can add new consumers without changing producers

**Benefits**:
- Easy to extend with new processing steps
- Can replay historical events
- Scales to high throughput

### 5. Stateless Processing

**Why**: Enables horizontal scaling

**How**:
- Lambda functions are stateless
- State machine manages workflow state
- Data stored in DynamoDB (separate service)

**Benefits**:
- Can run multiple Lambda instances in parallel
- No shared state to synchronize
- Better fault isolation

## Scalability Considerations

### Current Configuration
- **Kafka**: 1 partition, 1 replica (development)
- **Lambda**: Single execution (sequential)
- **DynamoDB**: On-demand billing (auto-scaling)

### Production Scaling
- **Kafka**: Multiple partitions for parallelism
- **Lambda**: Concurrent executions per partition
- **DynamoDB**: Provisioned capacity or on-demand
- **Step Functions**: Built-in parallelization for independent tasks

## Security Considerations

### Current State (Development)
- LocalStack uses default credentials
- No authentication between services
- All traffic on localhost

### Production Hardening
1. **IAM Roles**: Least privilege role per service
2. **VPC**: Network isolation
3. **Encryption**: TLS for data in transit, encryption at rest
4. **Audit Logging**: CloudTrail for API calls
5. **Secrets Management**: AWS Secrets Manager for credentials
6. **Rate Limiting**: Protect against DDoS and abuse

## Failure Scenarios

### Lambda Timeout
- **Trigger**: Lambda runs longer than timeout (60s)
- **Handling**: Automatic retry, then Catch block
- **Recovery**: Increase timeout or optimize code

### Kafka Broker Unavailable
- **Trigger**: Kafka cluster crashes
- **Handling**: Producer buffers messages, consumer retries
- **Recovery**: Restart Kafka, messages replay from topic

### DynamoDB Conditional Write Fails
- **Trigger**: Duplicate document ID
- **Handling**: Lambda returns `duplicate` status
- **Recovery**: Execution succeeds, no DB entry created

### Step Function State Timeout
- **Trigger**: State runs longer than configured timeout
- **Handling**: Automatic timeout error, retry, then Catch
- **Recovery**: Adjust timeout configuration

### Network Partition
- **Trigger**: Service can't reach another service
- **Handling**: Timeouts, retries, eventual Catch
- **Recovery**: Restore connectivity, retries succeed

## Monitoring and Observability

### Metrics Available
1. **Execution Metrics** (from Step Functions):
   - Execution duration
   - State latencies
   - Success/failure rates

2. **Lambda Metrics** (if enabled):
   - Invocation count
   - Duration
   - Error count
   - Throttled requests

3. **Kafka Metrics** (from Strimzi):
   - Messages produced/consumed
   - Consumer lag
   - Broker health

4. **DynamoDB Metrics**:
   - Read/write units consumed
   - Item count
   - Latency

### Custom Monitoring
The `generate_report.py` script provides:
- Percentile latencies per state (P50, P95)
- Execution count
- JSON output for integration

## Cost Optimization

### LocalStack Usage
- **Zero cloud costs** for development and testing
- Full parity with AWS services
- Instant feedback loop

### Lambda Cost Factors
- Invocation count (per 1M: $0.20)
- Duration (per GB-second: $0.0000166667)
- Each function should complete in < 1 minute

### DynamoDB Cost Factors
- **On-demand**: Per million read/write units
- **Provisioned**: Fixed capacity cost
- **Storage**: Per GB per month

### Kafka Cost Factors
- Self-managed in Kubernetes (no direct AWS cost)
- Only infrastructure costs (Minikube/EC2)

## Future Enhancements

1. **Parallel Processing**: 
   - Use Map state to process multiple documents
   - Set parallelism limits to avoid resource exhaustion

2. **Workflow Versioning**:
   - Multiple state machine versions
   - Gradual rollout of new versions

3. **Long-Running Tasks**:
   - Use Wait state with SQS for polling patterns
   - Implement job queue for human tasks

4. **Real-Time Alerting**:
   - SNS subscriptions to email/SMS
   - CloudWatch dashboards

5. **Advanced Monitoring**:
   - X-Ray tracing for distributed tracing
   - Custom metrics to CloudWatch

6. **Batch Processing**:
   - Use batch Map state for bulk document processing
   - Optimize for throughput vs. latency

## References

- [AWS Step Functions Best Practices](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-service-integration.html)
- [Kafka Partition Strategy](https://kafka.apache.org/documentation/#intro_partitions)
- [DynamoDB Best Practices](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/best-practices.html)
- [Idempotency Patterns](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/idempotency.html)
- [Microservices Resilience Patterns](https://docs.aws.amazon.com/prescriptive-guidance/latest/resilience/)
