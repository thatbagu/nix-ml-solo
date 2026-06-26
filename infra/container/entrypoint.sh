#!/bin/sh
# SageMaker entrypoint — 1:1 devenv environment at startup.
#
# The devenv profile closure is baked into the image as Docker layers
# (one layer per Nix package). devenv-load.sh contains the evaluated
# devenv.nix env block — all Nix store paths in it are already present.
# uv sync installs PyPI packages from the exact uv.lock used locally.
set -eu

MODEL_DIR="${MODEL_DIR:-/opt/ml/model}"

# ── Activate devenv environment (env vars, PATH, Nix store paths) ─────────────
if [ -f "$MODEL_DIR/devenv-load.sh" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$MODEL_DIR/devenv-load.sh"
  set +a
fi

# Override DEVENV_ROOT to point at the model directory in the container
export DEVENV_ROOT="$MODEL_DIR"

# ── Activate pre-baked venv (installed at image build time, no internet needed) ─
# VENV_DIR defaults to /venv (container path); override for local testing.
VENV_DIR="${VENV_DIR:-/venv}"
if [ -d "$VENV_DIR" ]; then
  export VIRTUAL_ENV="$VENV_DIR"
  export PATH="$VENV_DIR/bin:$PATH"
fi

# ── SageMaker Training ────────────────────────────────────────────────────────
if [ -n "${TRAINING_SCRIPT:-}" ]; then
  case "$TRAINING_SCRIPT" in
    *.ipynb)
      OUT_NB="/opt/ml/output/data/executed.ipynb"
      echo "[entrypoint] papermill $TRAINING_SCRIPT $OUT_NB" >&2
      # shellcheck disable=SC2086
      exec papermill "$TRAINING_SCRIPT" "$OUT_NB" ${TRAINING_SCRIPT_ARGS:-}
      ;;
    *)
      echo "[entrypoint] python $TRAINING_SCRIPT" >&2
      # shellcheck disable=SC2086
      exec python "$TRAINING_SCRIPT" ${TRAINING_SCRIPT_ARGS:-}
      ;;
  esac
fi

# ── SageMaker Inference (default) ────────────────────────────────────────────
# Locate the MLflow model — deploy packs it under model/ inside the tarball.
if [ -d "$MODEL_DIR/model" ]; then
  MODEL_URI="$MODEL_DIR/model"
else
  MODEL_URI="$MODEL_DIR"
fi

echo "[entrypoint] mlflow models serve on :8080 (model: $MODEL_URI)" >&2
exec "$VENV_DIR/bin/python" -m mlflow models serve \
  --model-uri "$MODEL_URI" \
  --host 0.0.0.0 \
  --port 8080 \
  --env-manager local
