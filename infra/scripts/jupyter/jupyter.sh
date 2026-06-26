#!/usr/bin/env bash
set -euo pipefail

PORT="${JUPYTER_PORT:-8888}"

case "${INFRA_MODE:-local}" in
  cloud)
    source "$PROJECT_ROOT/infra/scripts/_lib.sh"
    _require_ssh
    bash "$PROJECT_ROOT/infra/scripts/jupyter/jupyter-ec2.sh"
    ;;
  *)
    echo "Opening JupyterLab locally…"
    cd "$PROJECT_ROOT"
    uv run jupyter lab --no-browser --port "${PORT}"
    ;;
esac
