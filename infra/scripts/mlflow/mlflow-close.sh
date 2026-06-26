#!/usr/bin/env bash
set -euo pipefail

PORT="${MLFLOW_PORT:-5000}"
pkill -f "ssh.*${PORT}:localhost:${PORT}" && echo "MLflow tunnel closed." || echo "No tunnel running."
