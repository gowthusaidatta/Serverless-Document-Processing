.PHONY: help setup start stop clean logs test report install-deps

help:
	@echo "Serverless Document Processing Pipeline - Available Commands"
	@echo ""
	@echo "Setup & Installation:"
	@echo "  make install-deps      Install Python dependencies"
	@echo "  make setup             Initial setup (start services, provision resources)"
	@echo ""
	@echo "Service Management:"
	@echo "  make start             Start LocalStack and other services"
	@echo "  make stop              Stop all services"
	@echo "  make restart           Restart all services"
	@echo "  make clean             Clean up all resources"
	@echo ""
	@echo "Development:"
	@echo "  make logs              View LocalStack logs"
	@echo "  make init-aws          Initialize AWS resources in LocalStack"
	@echo "  make kafka-setup       Setup Kafka cluster and topics"
	@echo ""
	@echo "Testing:"
	@echo "  make test-simple       Send a simple claim"
	@echo "  make test-fraud        Send a claim with fraud indicators"
	@echo "  make test-idempotency  Test idempotency with duplicate IDs"
	@echo "  make test-all          Run all tests"
	@echo ""
	@echo "Monitoring:"
	@echo "  make report            Generate performance report"
	@echo "  make status            Check system status"
	@echo ""

install-deps:
	@echo "Installing Python dependencies..."
	pip install -r requirements.txt
	@echo "Dependencies installed!"

setup: start init-aws kafka-setup
	@echo "Setup complete! The system is ready to use."
	@echo "Start the consumer: python scripts/consumer.py --bootstrap-servers localhost:9093"
	@echo "In another terminal, send messages: python scripts/producer.py --bootstrap-servers localhost:9093"

start:
	@echo "Starting LocalStack..."
	docker-compose up -d
	@echo "Waiting for LocalStack to be healthy..."
	@sleep 30
	@echo "LocalStack is running!"

stop:
	@echo "Stopping services..."
	docker-compose down
	@echo "Services stopped!"

restart: stop start

clean:
	@echo "Cleaning up resources..."
	docker-compose down -v
	rm -rf .localstack/
	rm -f lambda_functions/*/function.zip
	rm -f report.json
	@echo "Cleanup complete!"

logs:
	docker-compose logs -f localstack

init-aws:
	@echo "Initializing AWS resources..."
	chmod +x scripts/init-aws.sh
	./scripts/init-aws.sh

kafka-setup:
	@echo "Deploying Kafka cluster and topics..."
	kubectl apply -f k8s/kafka-cluster.yml
	@echo "Waiting for Kafka cluster to be ready (this may take 1-2 minutes)..."
	kubectl wait --for=condition=Ready pod -l strimzi.io/name=claims-kafka-kafka-0 -n default --timeout=300s || true
	kubectl apply -f k8s/kafka-topics.yml
	@echo "Kafka setup complete!"

test-simple:
	@echo "Sending a simple claim..."
	python scripts/producer.py --bootstrap-servers localhost:9093

test-fraud:
	@echo "Sending a claim with fraud indicators..."
	python scripts/producer.py --bootstrap-servers localhost:9093 --test-fraud

test-idempotency:
	@echo "Testing idempotency with duplicate IDs..."
	python scripts/producer.py --bootstrap-servers localhost:9093 --repeat-id "test-idempotency-doc-12345"

test-all: test-simple test-fraud test-idempotency
	@echo "All tests completed!"

report:
	@echo "Generating performance report..."
	python scripts/generate_report.py --max-executions 10

status:
	@echo "=== LocalStack Status ==="
	@docker-compose ps || echo "LocalStack not running"
	@echo ""
	@echo "=== AWS Resources ==="
	@awslocal lambda list-functions --query 'Functions[*].FunctionName' --output table || echo "Cannot connect to LocalStack"
	@echo ""
	@echo "=== Kafka Status ==="
	@kubectl get kafka || echo "Minikube not running"
	@kubectl get kafkatopic || echo "No Kafka topics found"

.PHONY: docs
docs:
	@echo "Opening README..."
	@open README.md || xdg-open README.md || start README.md
