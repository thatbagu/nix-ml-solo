#!/usr/bin/env bash
set -euo pipefail

PORT="${MLFLOW_PORT:-5000}"
echo "Starting local MLflow server at $MLFLOW_TRACKING_URI"
uv run mlflow server \
  --host 127.0.0.1 \
  --port "${PORT}" \
  --default-artifact-root "$PROJECT_ROOT/mlruns" \
  --backend-store-uri "sqlite:///$PROJECT_ROOT/mlflow.db"
