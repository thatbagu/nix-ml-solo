#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"

MODE="${INFRA_MODE:-local}"
TF_DIR="$PROJECT_ROOT/infra/terraform"

echo ""
echo "  nix-ml-solo  [mode: $MODE]"
echo "  ─────────────────────────────────────────────"

if [ "$MODE" = "cloud" ]; then
  # EC2
  EC2_IP=$(cd "$TF_DIR" && tofu output -raw ec2_public_ip 2>/dev/null || echo "")
  if [ -n "$EC2_IP" ]; then
    if ssh -i "$SSH_IDENTITY_FILE" -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no "ml@$EC2_IP" true 2>/dev/null; then
      echo "  EC2           ✓  $EC2_IP"
    else
      echo "  EC2           ✗  $EC2_IP (unreachable)"
    fi
  else
    echo "  EC2           —  not deployed"
  fi

  # File sync
  if mutagen sync list nix-ml-solo 2>/dev/null | grep -q "Watching"; then
    echo "  File sync     ✓  running"
  else
    echo "  File sync     ✗  not running  (run: sync-ec2)"
  fi

  # MLflow tunnel
  if curl -sf http://localhost:5000/health > /dev/null 2>&1; then
    echo "  MLflow        ✓  http://localhost:5000"
  else
    echo "  MLflow        ✗  tunnel not open  (run: mlflow-open)"
  fi

  # Jupyter tunnel
  if curl -sf http://localhost:8888/api 2>/dev/null | grep -q "version"; then
    echo "  Jupyter       ✓  http://localhost:8888"
  else
    echo "  Jupyter       —  not open  (run: jupyter)"
  fi

  # SageMaker endpoint
  PROJECT="${TF_VAR_project:-nix-ml-solo}"
  ENV="${TF_VAR_environment:-dev}"
  ENDPOINT="$PROJECT-$ENV-endpoint"
  EP_STATUS=$(aws sagemaker describe-endpoint \
    --endpoint-name "$ENDPOINT" \
    --region "$AWS_DEFAULT_REGION" \
    --query 'EndpointStatus' \
    --output text 2>/dev/null || echo "NotDeployed")
  case "$EP_STATUS" in
    InService)   echo "  Endpoint      ✓  $ENDPOINT (InService)" ;;
    NotDeployed) echo "  Endpoint      —  not deployed" ;;
    *)           echo "  Endpoint      ⚡  $ENDPOINT ($EP_STATUS)" ;;
  esac

else
  # Local mode
  if curl -sf http://localhost:5000/health > /dev/null 2>&1; then
    echo "  MLflow        ✓  http://localhost:5000"
  else
    echo "  MLflow        ✗  not running  (run: mlflow-start)"
  fi

  if curl -sf http://localhost:5001/ping > /dev/null 2>&1; then
    echo "  Inference     ✓  http://localhost:5001"
  else
    echo "  Inference     —  not running"
  fi
fi

echo "  ─────────────────────────────────────────────"
echo ""
