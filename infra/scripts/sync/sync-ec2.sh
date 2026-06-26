#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud
_require_ssh

PROJECT="${TF_VAR_project:-nix-ml-solo}"
SSH_HOST="${PROJECT}-ec2"

EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)

# Write SSH config entry so mutagen can reach EC2 with the right key.
# The IP is dynamic (changes on EC2 restart), so we regenerate each time.
mkdir -p "$HOME/.ssh/config.d"
cat > "$HOME/.ssh/config.d/${PROJECT}" <<EOF
Host ${SSH_HOST}
  HostName $EC2_IP
  User ml
  IdentityFile ${SSH_IDENTITY_FILE:-$HOME/.ssh/${PROJECT}}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF

# Ensure ~/.ssh/config includes config.d (idempotent)
if ! grep -q "Include config.d/\*" "$HOME/.ssh/config" 2>/dev/null; then
  printf "Include config.d/*\n\n" | cat - "$HOME/.ssh/config" 2>/dev/null > /tmp/_sshcfg \
    && mv /tmp/_sshcfg "$HOME/.ssh/config" \
    || echo "Include config.d/*" > "$HOME/.ssh/config"
fi

# Terminate any existing session and recreate (handles IP changes after restart)
mutagen sync terminate "${PROJECT}" 2>/dev/null || true
mutagen sync create \
  --name "${PROJECT}" \
  --mode two-way-resolved \
  --ignore-vcs \
  --ignore '.devenv' --ignore '.direnv' --ignore '.devenv-configs' \
  --ignore '.venv' --ignore 'mlruns' --ignore '__pycache__' \
  --ignore '*.pyc' --ignore '*.db' \
  "$PROJECT_ROOT" \
  "${SSH_HOST}:/home/ml/project"

echo "Sync session started — bidirectional, real-time."
echo "Run 'sync-ec2-status' to check, 'sync-ec2-stop' to terminate."
