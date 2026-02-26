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
- `notebooks/TestData.csv` - Test data for stream ingestion (CSV with ticker and price columns)

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

1. Create the boto3 Lambda layer (no S3). Run the build script and note the printed `Boto3LayerArn` for the next step:

```bash
./scripts/build-boto3-layer.sh
# Output includes: Boto3LayerArn for CloudFormation parameter: arn:aws:lambda:REGION:ACCOUNT:layer:boto3-layer:VERSION
```

2. Deploy CloudFormation stack (pass the layer ARN from step 1):

```bash
# With default Knowledge Base and Data Source names
aws cloudformation create-stack \
  --stack-name BedrockStreamIngest \
  --template-body file://templates/bedrock-kb-stream-ingest.yml \
  --parameters ParameterKey=Boto3LayerArn,ParameterValue=arn:aws:lambda:REGION:ACCOUNT:layer:boto3-layer:VERSION \
  --capabilities CAPABILITY_NAMED_IAM

# Or with custom names
aws cloudformation create-stack \
  --stack-name BedrockStreamIngest \
  --template-body file://templates/bedrock-kb-stream-ingest.yml \
  --parameters \
    ParameterKey=Boto3LayerArn,ParameterValue=arn:aws:lambda:REGION:ACCOUNT:layer:boto3-layer:VERSION \
    ParameterKey=KnowledgeBaseName,ParameterValue=BedrockStreamIngestKnowledgeBase \
    ParameterKey=DataSourceName,ParameterValue=BedrockStreamIngestKBCustomDS \
  --capabilities CAPABILITY_NAMED_IAM
```

3. Wait for stack creation (20-30 minutes for MSK cluster):

```bash
aws cloudformation wait stack-create-complete --stack-name BedrockStreamIngest
```

**Updating the stack** (e.g. to change the boto3 layer or other parameters):

```bash
# If you updated the boto3 layer, run the build script and use the new ARN:
./scripts/build-boto3-layer.sh

# Update the stack with the new layer ARN (replace with the ARN from the script output)
aws cloudformation update-stack \
  --stack-name BedrockStreamIngest \
  --template-body file://templates/bedrock-kb-stream-ingest.yml \
  --parameters ParameterKey=Boto3LayerArn,ParameterValue=arn:aws:lambda:REGION:ACCOUNT:layer:boto3-layer:VERSION \
  --capabilities CAPABILITY_NAMED_IAM

# Or with all parameters (use existing values for parameters you are not changing)
aws cloudformation update-stack \
  --stack-name BedrockStreamIngest \
  --template-body file://templates/bedrock-kb-stream-ingest.yml \
  --parameters \
    ParameterKey=Boto3LayerArn,ParameterValue=arn:aws:lambda:REGION:ACCOUNT:layer:boto3-layer:VERSION \
    ParameterKey=KnowledgeBaseName,ParameterValue=BedrockStreamIngestKnowledgeBase \
    ParameterKey=DataSourceName,ParameterValue=BedrockStreamIngestKBCustomDS \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation wait stack-update-complete --stack-name BedrockStreamIngest
```

4. Access SageMaker Studio from AWS Console and open `notebooks/1.Setup.ipynb`

5. Run all cells in `1.Setup.ipynb` sequentially:

   - Checks and upgrades boto3/botocore to version >= 1.42.46 in the SageMaker notebook environment (required for MSK Topic Management API; Lambda uses a layer for boto3)
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
- Reads test data from `notebooks/TestData.csv` (same directory as notebook; CSV with `ticker` and `price` columns)
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

Embedded in CloudFormation template:

- Runtime: Python 3.13
- Timeout: 900 seconds
- Reserved concurrency: 1
- Uses a Lambda layer for boto3 >= 1.42.46 (no runtime pip install; create with `scripts/build-boto3-layer.sh`)
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

## Cost Optimization

- **Lambda reserved concurrency**: Set to 1 for this sample (1 topic, 1 partition). See `docs/cost-analysis-lambda-msk.md` for analysis.
- **Lambda boto3**: Provided via a Lambda layer (boto3 >= 1.42.46); no runtime pip install, which shortens cold start time.
- **MSK**: Provisioned (kafka.t3.small × 2) is appropriate for this sample. Delete the stack when not in use to avoid idle broker costs. See `docs/cost-analysis-lambda-msk.md` for MSK Provisioned vs Serverless pricing comparison.

## Notebook Formatting Rules

Jupyter notebook (`.ipynb`) files must match the upstream (aws-samples) format exactly:

- **JSON indentation**: 1 space (this is the SageMaker Studio default). Do NOT use 2-space or 4-space indentation for the notebook JSON structure.
- **Trailing whitespace in source lines**: Preserve as-is. Do NOT strip trailing spaces from existing code lines — upstream has intentional trailing whitespace in some cells.
- **Python code indentation inside cells**: 4 spaces (standard Python).
- **Metadata**: Keep `metadata`, `nbformat`, `nbformat_minor` identical to upstream for unchanged notebooks.

To reformat notebooks to 1-space JSON indentation (e.g., after an editor changes the format):

```bash
python3 -c "
import json
for path in ['notebooks/1.Setup.ipynb', 'notebooks/2.StreamIngest.ipynb', 'notebooks/3.Cleanup.ipynb']:
    with open(path) as f:
        data = json.load(f)
    with open(path, 'w') as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
        f.write('\n')
"
```

**Important**: After reformatting, verify with `git diff` that only intended changes appear. If upstream trailing whitespace was lost, restore it from `aws-samples/main`.

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
- [Lambda reserved concurrency](https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html) - Configuring reserved concurrency for a function
- [What is MSK Serverless?](https://docs.aws.amazon.com/msk/latest/developerguide/serverless.html) - MSK Serverless overview and when to use
