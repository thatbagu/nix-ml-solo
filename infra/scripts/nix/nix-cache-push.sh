#!/usr/bin/env bash
set -euo pipefail

BUCKET=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw nix_cache_bucket 2>/dev/null)
REGION="$AWS_DEFAULT_REGION"

if [ -z "$BUCKET" ]; then
  echo "Error: could not read nix_cache_bucket from terraform output. Run tf-apply first." >&2
  exit 1
fi

PROFILE_PATH=$(readlink -f "$DEVENV_ROOT/.devenv/profile" 2>/dev/null || true)
if [ -z "$PROFILE_PATH" ] || [ ! -e "$PROFILE_PATH" ]; then
  echo "Error: devenv profile not found. Run 'direnv reload' first." >&2
  exit 1
fi

echo "Pushing closure of $PROFILE_PATH to s3://$BUCKET ..."
nix copy --to "s3://$BUCKET?region=$REGION" "$PROFILE_PATH"
echo "Done."
