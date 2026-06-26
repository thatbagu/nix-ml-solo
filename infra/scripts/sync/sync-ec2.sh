#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud
_require_ssh

EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)

# Write SSH config entry so mutagen can reach EC2 with the right key.
# The IP is dynamic (changes on EC2 restart), so we regenerate each time.
mkdir -p "$HOME/.ssh/config.d"
cat > "$HOME/.ssh/config.d/nix-ml-solo" <<EOF
Host nix-ml-solo-ec2
  HostName $EC2_IP
  User ml
  IdentityFile ${SSH_IDENTITY_FILE:-$HOME/.ssh/nix-ml-solo}
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
mutagen sync terminate nix-ml-solo 2>/dev/null || true
mutagen sync create \
  --name nix-ml-solo \
  --mode two-way-resolved \
  --ignore-vcs \
  --ignore '.devenv' --ignore '.direnv' --ignore '.devenv-configs' \
  --ignore '.venv' --ignore 'mlruns' --ignore '__pycache__' \
  --ignore '*.pyc' --ignore '*.db' \
  "$PROJECT_ROOT" \
  "nix-ml-solo-ec2:/home/ml/project"

echo "Sync session started — bidirectional, real-time."
echo "Run 'sync-ec2-status' to check, 'sync-ec2-stop' to terminate."
