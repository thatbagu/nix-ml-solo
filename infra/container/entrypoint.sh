#!/bin/sh
# Entrypoint for SageMaker Training and Inference containers.
# Python deps are pre-installed via uv sync in the Dockerfile.
# Supports both .py scripts and .ipynb notebooks (via papermill).
set -eu

AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
NIX_CACHE_BUCKET="${NIX_CACHE_BUCKET:-}"

# Configure S3 binary cache for any nix operations inside the container
if [ -n "$NIX_CACHE_BUCKET" ]; then
  echo "extra-substituters = s3://${NIX_CACHE_BUCKET}?region=${AWS_REGION}" >> /etc/nix/nix.conf
  echo "trusted-users = root" >> /etc/nix/nix.conf
fi

# SageMaker Training: TRAINING_SCRIPT set by the train devenv script
if [ $# -eq 0 ] && [ -n "${TRAINING_SCRIPT:-}" ]; then
  case "$TRAINING_SCRIPT" in
    *.ipynb)
      # Executed notebook written to SageMaker output dir so it lands in S3
      OUT_NB="/opt/ml/output/data/executed.ipynb"
      echo "[entrypoint] Running notebook: papermill $TRAINING_SCRIPT $OUT_NB ${TRAINING_SCRIPT_ARGS:-}" >&2
      # shellcheck disable=SC2086
      exec uv run papermill "$TRAINING_SCRIPT" "$OUT_NB" ${TRAINING_SCRIPT_ARGS:-}
      ;;
    *)
      echo "[entrypoint] Running script: uv run python $TRAINING_SCRIPT ${TRAINING_SCRIPT_ARGS:-}" >&2
      # shellcheck disable=SC2086
      exec uv run python "$TRAINING_SCRIPT" ${TRAINING_SCRIPT_ARGS:-}
      ;;
  esac
fi

exec "$@"
