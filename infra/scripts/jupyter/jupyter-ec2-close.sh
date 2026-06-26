#!/usr/bin/env bash
set -euo pipefail

pkill -f "ssh.*8888:localhost:8888" && echo "Jupyter tunnel closed." || echo "No tunnel running."

EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip 2>/dev/null || true)
if [ -n "${EC2_IP:-}" ] && [ -n "${SSH_IDENTITY_FILE:-}" ]; then
  ssh -i "$SSH_IDENTITY_FILE" -o IdentitiesOnly=yes -o IdentityAgent=none \
    "ml@$EC2_IP" "pkill -x jupyter-lab || true" 2>/dev/null || true
fi
