#!/usr/bin/env bash
# Build a Lambda layer zip with boto3 >= 1.42.46 and publish it via AWS CLI (no S3).
# Usage: ./scripts/build-boto3-layer.sh [--profile PROFILE] [--region REGION] [--attach FUNCTION_NAME]
#   --profile: optional; AWS CLI profile name to use.
#   --region:  optional; AWS region to use (e.g. us-east-1).
#   --attach:  optional; if set, run update-function-configuration to attach the new layer to the function.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build/layer"
LAYER_NAME="boto3-layer"
ZIP_NAME="boto3-layer.zip"
COMPATIBLE_RUNTIME="python3.13"

ATTACH_FUNCTION_NAME=""
AWS_PROFILE=""
AWS_REGION=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --attach)
      ATTACH_FUNCTION_NAME="${2:-}"
      shift 2
      ;;
    --profile)
      AWS_PROFILE="${2:-}"
      shift 2
      ;;
    --region)
      AWS_REGION="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--profile PROFILE] [--region REGION] [--attach FUNCTION_NAME]"
      exit 1
      ;;
  esac
done

# Build AWS CLI common options from --profile and --region
AWS_OPTS=()
if [[ -n "$AWS_PROFILE" ]]; then
  AWS_OPTS+=(--profile "$AWS_PROFILE")
fi
if [[ -n "$AWS_REGION" ]]; then
  AWS_OPTS+=(--region "$AWS_REGION")
fi

if [[ -n "$AWS_PROFILE" ]]; then
  echo "==> Using AWS profile: $AWS_PROFILE"
fi
if [[ -n "$AWS_REGION" ]]; then
  echo "==> Using AWS region: $AWS_REGION"
fi

echo "==> Creating build directory: $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> Installing boto3>=1.42.46 into python/"
pip install --quiet --target ./python 'boto3>=1.42.46'

echo "==> Creating zip (root must contain python/)"
zip -r -q "$ZIP_NAME" python/

ZIP_PATH="$(pwd)/$ZIP_NAME"
echo "==> Publishing layer: aws lambda publish-layer-version --layer-name $LAYER_NAME --zip-file fileb://$ZIP_NAME --compatible-runtimes $COMPATIBLE_RUNTIME"
LAYER_VERSION_ARN=$(aws lambda publish-layer-version \
  "${AWS_OPTS[@]}" \
  --layer-name "$LAYER_NAME" \
  --zip-file "fileb://$ZIP_PATH" \
  --compatible-runtimes "$COMPATIBLE_RUNTIME" \
  --description "boto3 >= 1.42.46 for Lambda (MSK Topic Management API, etc.)" \
  --query 'LayerVersionArn' \
  --output text)

echo ""
echo "Boto3LayerArn for CloudFormation parameter:"
echo "  $LAYER_VERSION_ARN"
echo ""
echo "Example create-stack:"
echo "  ParameterKey=Boto3LayerArn,ParameterValue=$LAYER_VERSION_ARN"

if [[ -n "$ATTACH_FUNCTION_NAME" ]]; then
  echo ""
  echo "==> Attaching layer to function: $ATTACH_FUNCTION_NAME"
  aws lambda update-function-configuration \
    "${AWS_OPTS[@]}" \
    --function-name "$ATTACH_FUNCTION_NAME" \
    --layers "$LAYER_VERSION_ARN" \
    --output json > /dev/null
  echo "Done. Function $ATTACH_FUNCTION_NAME now uses layer $LAYER_VERSION_ARN"
fi
