#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud
_require_ssh

CONFIG="$DEVENV_ROOT/.devenv-configs/nixos-config.nix"
if [ ! -f "$CONFIG" ]; then
  echo "Error: $CONFIG not found. Run 'tf-apply' first." >&2; exit 1
fi

EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
SSH="ssh -i $SSH_IDENTITY_FILE -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new"

echo "Pushing NixOS config to $EC2_IP…"
$SSH "ml@$EC2_IP" "sudo tee /etc/nixos/configuration.nix > /dev/null" < "$CONFIG"

echo "Pushing devenv environment files…"
$SSH "ml@$EC2_IP" "mkdir -p /home/ml/project"
$SSH "ml@$EC2_IP" "cat > /home/ml/project/devenv.nix"  < "$DEVENV_ROOT/devenv.nix"
$SSH "ml@$EC2_IP" "cat > /home/ml/project/devenv.lock" < "$DEVENV_ROOT/devenv.lock"
for f in pyproject.toml uv.lock; do
  [ -f "$DEVENV_ROOT/$f" ] && $SSH "ml@$EC2_IP" "cat > /home/ml/project/$f" < "$DEVENV_ROOT/$f" || true
done

echo "Rebuilding NixOS (this takes a minute)…"
$SSH "ml@$EC2_IP" "sudo nixos-rebuild switch 2>&1"

echo "Restarting devenv-build to pick up new packages…"
$SSH "ml@$EC2_IP" "sudo systemctl restart devenv-build.service && sudo systemctl is-active --wait devenv-build.service"

echo "Done."
