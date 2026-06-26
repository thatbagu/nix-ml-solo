#!/usr/bin/env bash
# Package a trained model and deploy it for inference.
#
# Requires two artifacts:
#   1. MLflow run ID      — model weights + metadata fetched from MLflow
#   2. Inference script   — set INFERENCE_SCRIPT in devenv.nix or pass as arg
#
# SageMaker model.tar.gz layout:
#   code/inference.py    <- your inference script
#   <model files>        <- whatever MLflow logged (pkl, pt, etc.)
#
# No requirements.txt needed — all deps are baked into the container image
# via uv sync --frozen at docker build time (same uv.lock as local devenv).
#
# local mode:  mlflow models serve on localhost:5001
# cloud mode:  assemble tarball → S3 → create/update SageMaker endpoint
#
# Usage: deploy <mlflow-run-id> [mlflow-artifact-path]
# Examples:
#   deploy abc123def456
#   deploy abc123def456 my-model
set -euo pipefail

MODE="${INFRA_MODE:-local}"
RUN_ID="${1:-}"
ARTIFACT_PATH="${2:-model}"
INFERENCE_SCRIPT="${INFERENCE_SCRIPT:-}"

if [ -z "$RUN_ID" ]; then
  echo "Usage: deploy <mlflow-run-id> [artifact-path]" >&2
  echo ""
  echo "  mlflow-run-id    — from 'mlflow runs list' or the MLflow UI"
  echo "  artifact-path    — path logged in MLflow (default: 'model')"
  echo ""
  echo "Set INFERENCE_SCRIPT in devenv.nix or env to point at your inference.py"
  exit 1
fi

case "$MODE" in

  # ── Local ──────────────────────────────────────────────────────────────────
  local)
    echo "▶ Serving model locally"
    echo "  Run ID   : $RUN_ID"
    echo "  Artifact : $ARTIFACT_PATH"
    echo "  Endpoint : http://localhost:${INFERENCE_PORT:-5001}/invocations"
    echo ""
    echo "  Test with:"
    echo "    curl -X POST http://localhost:${INFERENCE_PORT:-5001}/invocations \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{\"dataframe_split\": {\"columns\": [...], \"data\": [[...]]}}'"
    echo ""
    echo "  Ctrl-C to stop."
    echo ""

    uv run mlflow models serve \
      --model-uri "runs:/$RUN_ID/$ARTIFACT_PATH" \
      --host 127.0.0.1 \
      --port "${INFERENCE_PORT:-5001}" \
      --env-manager local
    ;;

  # ── Cloud ──────────────────────────────────────────────────────────────────
  cloud)
    if [ -z "$INFERENCE_SCRIPT" ]; then
      echo "Error: INFERENCE_SCRIPT is not set." >&2
      echo "  Set it in devenv.nix:  env.INFERENCE_SCRIPT = \"src/inference.py\";" >&2
      echo "  or export it:          export INFERENCE_SCRIPT=src/inference.py" >&2
      exit 1
    fi

    if [ ! -f "$INFERENCE_SCRIPT" ]; then
      echo "Error: inference script not found: $INFERENCE_SCRIPT" >&2
      exit 1
    fi

    source "$PROJECT_ROOT/infra/scripts/_lib.sh"
    _require_ssh

    # Auto-ensure MLflow is reachable for artifact download
    if ! curl -sf "http://localhost:${MLFLOW_PORT:-5000}/health" > /dev/null 2>&1; then
      echo "[ deploy ] MLflow not reachable — connecting..."
      mlflow-open
    fi

    REGION="$AWS_DEFAULT_REGION"
    TF_DIR="$PROJECT_ROOT/infra/terraform"
    PROJECT="${TF_VAR_project:-ml-solo}"
    ENV="${TF_VAR_environment:-dev}"

    DVC_BUCKET=$(cd "$TF_DIR" && tofu output -raw dvc_bucket_name)
    ECR_URI=$(cd "$TF_DIR"    && tofu output -raw ecr_repo_uri)

    # ── Auto-build container if devenv profile or entrypoint changed ─────────
    DEVENV_PROFILE=$(readlink -f "$DEVENV_ROOT/.devenv/profile")
    PROFILE_HASH=$(basename "$DEVENV_PROFILE" | cut -c1-8)
    EP_HASH=$(sha256sum "$PROJECT_ROOT/infra/container/entrypoint.sh" | cut -c1-8)
    BUILD_TAG="build-${PROFILE_HASH}-${EP_HASH}"
    ECR_REPO="${ECR_URI##*/}"

    if aws ecr describe-images \
        --repository-name "$ECR_REPO" \
        --image-ids "imageTag=$BUILD_TAG" \
        --region "$REGION" \
        --output text &>/dev/null; then
      echo "  Container image up to date ($BUILD_TAG)"
    else
      echo "  Container changed ($BUILD_TAG) — rebuilding..."
      bash "$PROJECT_ROOT/infra/scripts/container-build.sh"
    fi

    MODEL_S3_KEY="model-artifacts/$RUN_ID/model.tar.gz"
    MODEL_S3_URI="s3://$DVC_BUCKET/$MODEL_S3_KEY"

    echo "▶ Packaging model for SageMaker"
    echo "  Run ID            : $RUN_ID"
    echo "  MLflow artifact   : $ARTIFACT_PATH"
    echo "  Inference script  : $INFERENCE_SCRIPT"
    echo "  Destination       : $MODEL_S3_URI"
    echo ""

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    # Download model artifacts from MLflow tracking server
    echo "  Fetching artifacts from MLflow..."
    uv run mlflow artifacts download \
      --run-id "$RUN_ID" \
      --artifact-path "$ARTIFACT_PATH" \
      --dst-path "$TMP_DIR/model"

    # SageMaker expects inference code under code/
    mkdir -p "$TMP_DIR/model/code"
    cp "$INFERENCE_SCRIPT" "$TMP_DIR/model/code/inference.py"

    # Pack uv.lock for PyPI packages and .devenv/load for the full devenv
    # environment (env vars, PATH, etc.) — Nix store paths in load are valid
    # because the exact closure is baked into the image as Docker layers.
    cp "$DEVENV_ROOT/uv.lock"          "$TMP_DIR/model/"
    cp "$DEVENV_ROOT/pyproject.toml"   "$TMP_DIR/model/"
    cp "$DEVENV_ROOT/.devenv/load-exports" "$TMP_DIR/model/devenv-load.sh"

    # Assemble model.tar.gz
    echo "  Assembling model.tar.gz..."
    tar -czf "$TMP_DIR/model.tar.gz" -C "$TMP_DIR/model" .

    # Upload to S3
    echo "  Uploading to $MODEL_S3_URI..."
    aws s3 cp "$TMP_DIR/model.tar.gz" "$MODEL_S3_URI" --region "$REGION"

    # ── Clean up stale endpoint before apply ─────────────────────────────────
    ENDPOINT_NAME="$PROJECT-$ENV-endpoint"
    ENDPOINT_STATUS=$(aws sagemaker describe-endpoint \
      --endpoint-name "$ENDPOINT_NAME" \
      --region "$REGION" \
      --query 'EndpointStatus' \
      --output text 2>/dev/null || echo "NotFound")

    case "$ENDPOINT_STATUS" in
      Failed|NotFound)
        if [ "$ENDPOINT_STATUS" = "Failed" ]; then
          echo "  Stale endpoint ($ENDPOINT_STATUS) — deleting..."
          aws sagemaker delete-endpoint \
            --endpoint-name "$ENDPOINT_NAME" \
            --region "$REGION"
          echo "  Waiting for deletion..."
          aws sagemaker wait endpoint-deleted \
            --endpoint-name "$ENDPOINT_NAME" \
            --region "$REGION"
        fi
        # Remove from Terraform state so apply recreates it cleanly
        (cd "$TF_DIR" && tofu state rm \
          "module.sagemaker[0].aws_sagemaker_endpoint.endpoint[0]") 2>/dev/null || true
        ;;
      InService)
        echo "  Endpoint: $ENDPOINT_STATUS"
        ;;
      Creating|Updating|SystemUpdating)
        echo "  Endpoint is $ENDPOINT_STATUS — waiting for terminal state before cleanup..."
        aws sagemaker wait endpoint-in-service \
          --endpoint-name "$ENDPOINT_NAME" \
          --region "$REGION" 2>/dev/null || true
        echo "  Deleting stale endpoint..."
        aws sagemaker delete-endpoint \
          --endpoint-name "$ENDPOINT_NAME" \
          --region "$REGION" 2>/dev/null || true
        aws sagemaker wait endpoint-deleted \
          --endpoint-name "$ENDPOINT_NAME" \
          --region "$REGION" 2>/dev/null || true
        (cd "$TF_DIR" && tofu state rm \
          "module.sagemaker[0].aws_sagemaker_endpoint.endpoint[0]") 2>/dev/null || true
        ;;
    esac

    # Deploy: update endpoint via targeted tf-apply
    echo ""
    echo "  Deploying SageMaker endpoint..."
    cd "$TF_DIR"
    tofu init -upgrade=false
    tofu apply -auto-approve \
      -var "sagemaker_model_image_uri=$ECR_URI:latest" \
      -var "sagemaker_model_s3_uri=$MODEL_S3_URI"

    PUBLIC_URL=$(cd "$TF_DIR" && tofu output -raw public_endpoint_url 2>/dev/null || true)

    echo ""
    echo "  ─────────────────────────────────────────────────────"
    echo "  Endpoint deployed: $ENDPOINT_NAME"
    echo "  Run ID          : $RUN_ID"
    echo ""
    echo "  Private (AWS SDK / CLI):"
    echo "    aws sagemaker-runtime invoke-endpoint \\"
    echo "      --endpoint-name $ENDPOINT_NAME \\"
    echo "      --content-type application/json \\"
    echo "      --body fileb:///tmp/payload.json \\"
    echo "      /tmp/out.json && cat /tmp/out.json"
    if [ -n "$PUBLIC_URL" ]; then
    echo ""
    echo "  Public (HTTP, no AWS auth):"
    echo "    $PUBLIC_URL"
    echo ""
    echo "    curl -X POST \"$PUBLIC_URL\" \\"
    echo "      -H \"Content-Type: application/json\" \\"
    echo "      -d '{\"dataframe_split\": {\"columns\": [...], \"data\": [[...]]}}'"
    fi
    echo ""
    echo "  Status: deploy-status"
    echo "  ─────────────────────────────────────────────────────"
    ;;

  *)
    echo "Unknown INFRA_MODE '$MODE'. Set to 'local' or 'cloud'." >&2
    exit 1
    ;;
esac
