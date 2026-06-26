#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"

PORT="${MLFLOW_PORT:-5000}"

case "${INFRA_MODE:-local}" in
cloud)
  _require_ssh
  EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
  pkill -f "ssh.*${PORT}:localhost:${PORT}" 2>/dev/null || true
  echo "Connecting to $EC2_IP — will retry until NixOS first-boot completes (5-15 min)…"
  until ssh \
    -f \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -i "$SSH_IDENTITY_FILE" \
    -N -L "${PORT}:localhost:${PORT}" \
    "ml@$EC2_IP" 2>/dev/null; do
    printf "  Not ready yet — retrying in 20s…\r"
    sleep 20
  done
  echo "Tunnel active → http://localhost:${PORT}  (mlflow-close to stop)"
  ;;
*)
  echo "Local mode — open http://localhost:${PORT} (start with: mlflow-start)"
  ;;
esac
