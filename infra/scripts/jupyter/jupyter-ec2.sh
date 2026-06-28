#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud
_require_ssh

PORT="${JUPYTER_PORT:-8888}"
_require_ec2_ip
SSH="ssh -i $SSH_IDENTITY_FILE -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

pkill -f "ssh.*${PORT}:localhost:${PORT}" 2>/dev/null || true

# Start JupyterLab on EC2 (if not running) and open tunnel — all in background.
# The inner until-loop retries until EC2 is SSH-reachable, then forks the tunnel.
(
  until $SSH "ml@$EC2_IP" "
    if ! pgrep -x jupyter-lab > /dev/null 2>&1; then
      mkdir -p /home/ml/project
      cd /home/ml/project
      nohup /run/current-system/sw/bin/devenv shell -- \
        jupyter lab \
        --no-browser \
        --port ${PORT} \
        --ip 127.0.0.1 \
        --ServerApp.token=\"\" \
        --ServerApp.password=\"\" \
        > /home/ml/jupyter.log 2>&1 &
      disown
      sleep 3
    fi
  " 2>/dev/null; do
    sleep 20
  done

  ssh \
    -f \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -i "$SSH_IDENTITY_FILE" \
    -N -L "${PORT}:localhost:${PORT}" \
    "ml@$EC2_IP"
) &
disown

echo "Tunnel starting in background → http://localhost:${PORT}  (jupyter-ec2-close to stop)"
