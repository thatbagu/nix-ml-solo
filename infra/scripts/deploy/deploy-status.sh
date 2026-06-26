#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"

case "${INFRA_MODE:-local}" in
  cloud)
    ENDPOINT="${TF_VAR_project:-nix-ml-solo}-${TF_VAR_environment:-dev}-endpoint"
    aws sagemaker describe-endpoint \
      --endpoint-name "$ENDPOINT" \
      --region "$AWS_DEFAULT_REGION" \
      --query '{Name:EndpointName,Status:EndpointStatus,Updated:LastModifiedTime}' \
      --output table
    ;;
  local)
    if curl -sf http://localhost:5001/ping > /dev/null 2>&1; then
      echo "Local inference server is running at http://localhost:5001"
    else
      echo "No local inference server running. Start with: deploy <run-id>"
    fi
    ;;
esac
