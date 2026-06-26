#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud
_require_ssh

SCRIPT="${1:-${TRAINING_SCRIPT:-}}"
[ $# -gt 0 ] && shift
[ "${1:-}" = "--" ] && shift
if [ -z "$SCRIPT" ]; then
  echo "Usage: train-on-ec2 <script.py|notebook.ipynb> [-- args...]" >&2; exit 1
fi

EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
SSH="ssh -i $SSH_IDENTITY_FILE -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
EC2_DVC=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw dvc_remote_url 2>/dev/null || echo "${DVC_REMOTE_URL:-}")

echo "▶ Training on EC2: $SCRIPT $*"
echo "  MLflow : http://localhost:5000"
echo ""

case "$SCRIPT" in
  *.ipynb)
    OUT="${SCRIPT%.ipynb}-executed.ipynb"
    $SSH "ml@$EC2_IP" "
      cd ~/project
      MLFLOW_TRACKING_URI=http://localhost:5000 \
      DVC_REMOTE_URL=$EC2_DVC \
      devenv shell -- uv run papermill '$SCRIPT' '$OUT' $*"
    ;;
  *)
    $SSH "ml@$EC2_IP" "
      cd ~/project
      MLFLOW_TRACKING_URI=http://localhost:5000 \
      DVC_REMOTE_URL=$EC2_DVC \
      devenv shell -- uv run python '$SCRIPT' $*"
    ;;
esac
