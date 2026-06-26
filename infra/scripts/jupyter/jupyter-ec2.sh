#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud
_require_ssh

EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
SSH="ssh -i $SSH_IDENTITY_FILE -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

# Start JupyterLab on EC2 if not already running.
# Uses devenv shell so all env vars (MLFLOW_TRACKING_URI, etc.) are inherited.
until $SSH "ml@$EC2_IP" "
  if ! pgrep -x jupyter-lab > /dev/null 2>&1; then
    mkdir -p /home/ml/project
    cd /home/ml/project
    nohup /run/current-system/sw/bin/devenv shell -- \
      jupyter lab \
      --no-browser \
      --port 8888 \
      --ip 127.0.0.1 \
      --ServerApp.token=\"\" \
      --ServerApp.password=\"\" \
      > /home/ml/jupyter.log 2>&1 &
    disown
    sleep 3
    echo 'JupyterLab started'
  else
    echo 'JupyterLab already running'
  fi
" 2>/dev/null; do
  printf "  EC2 not ready yet — retrying in 20s…\r"
  sleep 20
done

pkill -f "ssh.*8888:localhost:8888" 2>/dev/null || true

echo "Opening SSH tunnel → http://localhost:8888"
ssh \
  -f \
  -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=10 \
  -o BatchMode=yes \
  -i "$SSH_IDENTITY_FILE" \
  -N -L 8888:localhost:8888 \
  "ml@$EC2_IP"
echo "Tunnel active → http://localhost:8888  (jupyter-ec2-close to stop)"
