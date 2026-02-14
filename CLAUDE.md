# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sample project demonstrating stream ingestion from Apache Kafka (Amazon MSK) to Amazon Bedrock Knowledge Bases using custom data source connectors. The architecture consists of:

- Amazon MSK cluster as the streaming data source
- AWS Lambda function as Kafka consumer that ingests data into Bedrock KB
- Amazon Bedrock Knowledge Base with custom data source
- SageMaker Studio environment for running notebooks

## Directory Structure

- `templates/` - CloudFormation template for infrastructure provisioning
- `notebooks/` - Jupyter notebooks for setup, testing, and cleanup
- `data/` - Test data files (e.g., TestData.csv for stream ingestion testing)

## Architecture Flow

1. Data is published to MSK Kafka topic
2. Lambda function (event-triggered by MSK) consumes messages
3. Lambda transforms Kafka messages and calls `bedrock_agent_client.ingest_knowledge_base_documents()`
4. Data is ingested into Bedrock Knowledge Base as inline text content

## Infrastructure

All infrastructure is defined in `templates/bedrock-kb-stream-ingest.yml` (CloudFormation template):

- VPC with public/private subnets across 2 AZs
- MSK cluster (kafka.t3.small, 2 brokers, Kafka 3.8.x - AWS recommended version)
- Lambda function with MSK event source mapping
- SageMaker Studio domain and user profile
- IAM roles and security groups for all components

Kafka version 3.8.x is the AWS recommended version as documented in [Supported Apache Kafka versions](https://docs.aws.amazon.com/msk/latest/developerguide/supported-kafka-versions.html). This version includes compression level configuration support, performance improvements, and supports both ZooKeeper and KRaft metadata management.

Default stack name: `BedrockStreamIngest`

Default Kafka topic: `streamtopic`

## Development Workflow

### Initial Setup

1. Deploy CloudFormation stack:

```bash
# With default Knowledge Base and Data Source names
aws cloudformation create-stack \
  --stack-name BedrockStreamIngest \
  --template-body file://templates/bedrock-kb-stream-ingest.yml \
  --capabilities CAPABILITY_NAMED_IAM

# Or with custom names
aws cloudformation create-stack \
  --stack-name BedrockStreamIngest \
  --template-body file://templates/bedrock-kb-stream-ingest.yml \
  --parameters \
    ParameterKey=KnowledgeBaseName,ParameterValue=MyCustomKB \
    ParameterKey=DataSourceName,ParameterValue=MyCustomDS \
  --capabilities CAPABILITY_NAMED_IAM
```

2. Wait for stack creation (20-30 minutes for MSK cluster):

```bash
aws cloudformation wait stack-create-complete --stack-name BedrockStreamIngest
```

3. Access SageMaker Studio from AWS Console and open `notebooks/1.Setup.ipynb`

4. Run all cells in `1.Setup.ipynb` sequentially:

   - Checks and upgrades boto3/botocore to version >= 1.42.46 (required for MSK Topic Management API)
   - Retrieves MSK cluster ARN and bootstrap broker string
   - Creates Kafka topic using MSK CreateTopic API (no Kafka client installation required)
   - Verifies created topics using MSK ListTopics API
   - Creates Bedrock Knowledge Base and custom data source (manual steps via console)
   - Configures Lambda environment variables (KBID, DSID)
   - Creates MSK event source mapping for Lambda

   Note: If `AttributeError: 'Kafka' object has no attribute 'create_topic'` occurs, restart the kernel after running the upgrade cell.

### Testing Stream Ingestion

Run `notebooks/2.StreamIngest.ipynb`:

- Installs `confluent-kafka` Python library
- Reads test data from `data/TestData.csv` (CSV with `ticker` and `price` columns)
- Publishes messages to Kafka topic using confluent-kafka Producer
- Lambda automatically consumes and ingests to Bedrock KB

Note: The project previously used PyKafka, but migrated to confluent-kafka because PyKafka was archived on 2021-03-24 and is no longer maintained (last release: 2018-09-24). The confluent-kafka library (v2.13.0 as of January 2026) is actively maintained and provides Kafka 3.9.x compatibility through librdkafka. Version 2.13.0 supports all Kafka broker versions >= 0.8, including the latest Apache Kafka 3.9.1 which is currently the only actively supported 3.x release.

### Cleanup

Run `notebooks/3.Cleanup.ipynb`:

- Deletes Lambda event source mapping
- Additional cleanup via CloudFormation stack deletion

## Key Implementation Details

### Kafka Topic Management

Topics are created and managed using MSK public APIs (available since February 2026):

- `CreateTopic`: Create topics programmatically without Kafka client installation
- `ListTopics`: List and verify topics
- `UpdateTopic`: Modify topic configurations
- `DeleteTopic`: Remove topics

These APIs are available for MSK clusters running Kafka 3.6+ and require appropriate IAM permissions (`kafka:CreateTopic`, `kafka:ListTopics`, etc.). No additional charges apply for using these APIs.

### Lambda Function Code

Embedded in CloudFormation template (lines 808-904):

- Runtime: Python 3.13
- Timeout: 900 seconds
- Reserved concurrency: 50
- Installs boto3/botocore at runtime to `/tmp/`
- Decodes base64-encoded Kafka messages
- Constructs text payload: "At {timestamp} the price of {ticker} is {price}."
- Generates UUID for each document
- Calls `ingest_knowledge_base_documents()` with inline text content

### Required Environment Variables (Lambda)

Set automatically by `1.Setup.ipynb`:

- `KBID`: Bedrock Knowledge Base ID
- `DSID`: Custom Data Source ID

### Bedrock Knowledge Base Configuration

Created manually via AWS Console during setup:

- Name: Specified via CloudFormation parameter `KnowledgeBaseName` (default: `BedrockStreamIngestKnowledgeBase`)
- Data source: Custom, specified via CloudFormation parameter `DataSourceName` (default: `BedrockStreamIngestKBCustomDS`)
- Embeddings model: Titan Text Embeddings v2
- Source type: `IN_LINE` with `TEXT` content type

## Notebook Execution Order

Must be executed sequentially:

1. `1.Setup.ipynb` - Infrastructure configuration and manual setup steps
2. `2.StreamIngest.ipynb` - Test data ingestion
3. `3.Cleanup.ipynb` - Resource cleanup

Notebooks use IPython `%store` magic to persist variables between sessions.

## AWS Service Dependencies

- CloudFormation for infrastructure provisioning
- MSK (Managed Streaming for Apache Kafka)
- Lambda for event processing
- Bedrock Agent API for knowledge base ingestion
- SageMaker Studio for notebook execution
- CloudWatch Logs for monitoring

## IAM Permissions

Two main execution roles:

- `SageMakerExecutionRole`: Full access to MSK, Lambda, Bedrock, CloudFormation, S3
  - MSK Topic Management API permissions:
    - `kafka:ListTopics`, `kafka:CreateTopic`, `kafka:DescribeTopic`, `kafka:UpdateTopic`, `kafka:DeleteTopic`
    - Dependent actions: `kafka-cluster:CreateTopic`, `kafka-cluster:AlterTopic`, `kafka-cluster:DeleteTopic`, etc.
- `LambdaExecutionRole`: Access to MSK (read), Bedrock (ingest), CloudWatch Logs, VPC networking

## Network Configuration

- VPC CIDR: 10.0.0.0/16
- Public subnets: 10.0.0.0/20, 10.0.16.0/20
- Private subnets: 10.0.128.0/20, 10.0.144.0/20
- MSK and Lambda deployed in private subnets
- NAT Gateway for outbound internet access

## Troubleshooting

- If Lambda cannot connect to MSK: Check security group rules and event source mapping status
- If ingestion fails: Verify Lambda environment variables (KBID, DSID) are set correctly
- If notebooks fail: Ensure SageMaker execution role has required permissions
- MSK cluster takes 20-30 minutes to create/delete via CloudFormation

## References

- [AWS MSK Supported Apache Kafka Versions](https://docs.aws.amazon.com/msk/latest/developerguide/supported-kafka-versions.html) - Official documentation listing all supported Kafka versions and AWS recommendations
- [Apache Kafka 3.8.0 Release Notes](https://downloads.apache.org/kafka/3.8.0/RELEASE_NOTES.html) - Detailed release notes for Kafka 3.8.x
- [Apache Kafka Downloads](https://kafka.apache.org/community/downloads/) - Official Apache Kafka download page listing currently supported versions (3.9.1 for 3.x series as of February 2026)
- [confluent-kafka Python Client](https://pypi.org/project/confluent-kafka/) - Official PyPI page for confluent-kafka library
- [Amazon Bedrock IngestKnowledgeBaseDocuments API](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_IngestKnowledgeBaseDocuments.html) - API reference for stream ingestion
- [Amazon MSK Kafka Topics Public APIs](https://aws.amazon.com/jp/about-aws/whats-new/2026/02/amazon-msk-kafka-topics-public-apis/) - Announcement of CreateTopic, UpdateTopic, and DeleteTopic APIs
- [MSK CreateTopic API - Boto3 Documentation](https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/kafka/client/create_topic.html) - API reference for programmatic topic creation
