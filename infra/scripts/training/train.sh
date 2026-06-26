#!/usr/bin/env bash
# Run a training job. Supports .py scripts and .ipynb notebooks (via papermill).
# local mode:  runs directly, MLflow on localhost
# cloud mode:  submits SageMaker job, MLflow on EC2
#
# Usage: train <script.py|notebook.ipynb> [-- extra args]
# Examples:
#   train src/train.py
#   train notebooks/starter.ipynb
#   train src/train.py -- --epochs 10 --lr 0.001
#   train notebooks/starter.ipynb -- -p lr 0.001 -p epochs 10
set -euo pipefail

MODE="${INFRA_MODE:-local}"
SCRIPT="${1:-${TRAINING_SCRIPT:-}}"
[ $# -gt 0 ] && shift
[ "${1:-}" = "--" ] && shift

if [ -z "$SCRIPT" ]; then
  echo "Usage: train <script.py|notebook.ipynb> [-- args...]" >&2
  echo "  or set TRAINING_SCRIPT env var" >&2
  exit 1
fi

_is_notebook() { [[ "$1" == *.ipynb ]]; }

case "$MODE" in

  # ── Local ──────────────────────────────────────────────────────────────────
  local)
    echo "▶ Training locally: $SCRIPT $*"
    echo "  MLflow : $MLFLOW_TRACKING_URI"
    echo "  DVC    : $DVC_REMOTE_URL"
    echo ""

    if ! curl -sf "${MLFLOW_TRACKING_URI}/health" > /dev/null 2>&1; then
      echo "  MLflow is not running. Start it with: mlflow-start" >&2
      exit 1
    fi

    if _is_notebook "$SCRIPT"; then
      OUT="${SCRIPT%.ipynb}-executed.ipynb"
      echo "  Running notebook via papermill → $OUT"
      uv run papermill "$SCRIPT" "$OUT" "$@"
    else
      uv run python "$SCRIPT" "$@"
    fi
    ;;

  # ── Cloud ──────────────────────────────────────────────────────────────────
  cloud)
    # Auto-ensure file sync is running
    if ! mutagen sync list nix-ml-solo 2>/dev/null | grep -q "Watching"; then
      echo "[ train ] file sync not running — starting..."
      sync-ec2
    fi

    # Auto-ensure MLflow tunnel is open
    if ! curl -sf http://localhost:5000/health > /dev/null 2>&1; then
      echo "[ train ] MLflow tunnel not open — connecting..."
      mlflow-open
    fi

    SUFFIX="$(date +%Y%m%d-%H%M%S)"
    INSTANCE="${SAGEMAKER_TRAINING_INSTANCE:-ml.m5.xlarge}"
    REGION="$AWS_DEFAULT_REGION"
    TF_DIR="$PROJECT_ROOT/infra/terraform"

    DVC_BUCKET=$(cd "$TF_DIR" && tofu output -raw dvc_bucket_name)
    NIX_BUCKET=$(cd "$TF_DIR" && tofu output -raw nix_cache_bucket)
    ECR_URI=$(cd "$TF_DIR"    && tofu output -raw ecr_repo_uri)
    EC2_IP=$(cd "$TF_DIR"     && tofu output -raw ec2_public_ip)
    ROLE_ARN=$(aws iam list-roles \
      --query "Roles[?contains(RoleName,'sagemaker')].Arn" \
      --output text | awk '{print $1}')

    JOB_NAME="${TF_VAR_project:-ml-solo}-${SUFFIX}"
    EXTRA_ARGS="$*"

    # For notebooks, upload the .ipynb as a separate input channel so
    # SageMaker copies it to /opt/ml/input/data/notebook/ inside the container.
    if _is_notebook "$SCRIPT"; then
      NOTEBOOK_S3="s3://$DVC_BUCKET/notebooks/$(basename "$SCRIPT")"
      echo "  Uploading notebook to $NOTEBOOK_S3..."
      aws s3 cp "$SCRIPT" "$NOTEBOOK_S3" --region "$REGION"
      NOTEBOOK_CHANNEL=", {
        \"ChannelName\": \"notebook\",
        \"DataSource\": {
          \"S3DataSource\": {
            \"S3DataType\": \"S3Prefix\",
            \"S3Uri\": \"$NOTEBOOK_S3\",
            \"S3DataDistributionType\": \"FullyReplicated\"
          }
        }
      }"
      # Container will find the notebook at /opt/ml/input/data/notebook/<name>
      CONTAINER_SCRIPT="/opt/ml/input/data/notebook/$(basename "$SCRIPT")"
    else
      NOTEBOOK_CHANNEL=""
      CONTAINER_SCRIPT="$SCRIPT"
    fi

    echo "▶ Submitting SageMaker training job: $JOB_NAME"
    echo "  Script  : $SCRIPT"
    echo "  Instance: $INSTANCE"
    echo "  Image   : $ECR_URI:latest"
    echo "  Data    : s3://$DVC_BUCKET/data/train/"
    echo "  Output  : s3://$DVC_BUCKET/training-output/$JOB_NAME/"
    echo "  MLflow  : http://$EC2_IP:5000"
    echo ""

    aws sagemaker create-training-job \
      --region "$REGION" \
      --training-job-name "$JOB_NAME" \
      --algorithm-specification "TrainingImage=$ECR_URI:latest,TrainingInputMode=File" \
      --role-arn "$ROLE_ARN" \
      --input-data-config "[{
        \"ChannelName\": \"train\",
        \"DataSource\": {
          \"S3DataSource\": {
            \"S3DataType\": \"S3Prefix\",
            \"S3Uri\": \"s3://$DVC_BUCKET/data/train/\",
            \"S3DataDistributionType\": \"FullyReplicated\"
          }
        }
      }$NOTEBOOK_CHANNEL]" \
      --output-data-config "S3OutputPath=s3://$DVC_BUCKET/training-output/$JOB_NAME/" \
      --resource-config "InstanceType=$INSTANCE,InstanceCount=1,VolumeSizeInGB=30" \
      --stopping-condition "MaxRuntimeInSeconds=86400" \
      --environment "{
        \"NIX_CACHE_BUCKET\":     \"$NIX_BUCKET\",
        \"AWS_DEFAULT_REGION\":   \"$REGION\",
        \"MLFLOW_TRACKING_URI\":  \"http://$EC2_IP:5000\",
        \"TRAINING_SCRIPT\":      \"$CONTAINER_SCRIPT\",
        \"TRAINING_SCRIPT_ARGS\": \"$EXTRA_ARGS\"
      }"

    echo "Job submitted."
    echo "  train-status $JOB_NAME"
    echo "  train-logs   $JOB_NAME"
    if _is_notebook "$SCRIPT"; then
      echo "  Executed notebook: s3://$DVC_BUCKET/training-output/$JOB_NAME/output/executed.ipynb"
    fi
    ;;

  *)
    echo "Unknown INFRA_MODE '$MODE'. Set to 'local' or 'cloud'." >&2
    exit 1
    ;;
esac
