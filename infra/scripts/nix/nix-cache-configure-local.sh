#!/usr/bin/env bash
set -euo pipefail

BUCKET=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw nix_cache_bucket 2>/dev/null)
REGION="$AWS_DEFAULT_REGION"
NIX_CONF="$HOME/.config/nix/nix.conf"
mkdir -p "$(dirname "$NIX_CONF")"

if grep -q "$BUCKET" "$NIX_CONF" 2>/dev/null; then
  echo "S3 substituter already in $NIX_CONF — nothing to do."
else
  echo "" >> "$NIX_CONF"
  echo "# nix-ml-solo S3 binary cache" >> "$NIX_CONF"
  echo "extra-substituters = s3://$BUCKET?region=$REGION" >> "$NIX_CONF"
  echo "Appended s3://$BUCKET to $NIX_CONF"
  echo "Restart nix-daemon if needed: sudo systemctl restart nix-daemon"
fi
