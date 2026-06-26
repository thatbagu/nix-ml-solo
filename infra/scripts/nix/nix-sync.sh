#!/usr/bin/env bash
# Push the local devenv closure to the shared S3 nix cache.
# EC2 pulls from the same cache, so nixos-rebuild skips rebuilding anything
# you've already built locally.
set -euo pipefail

BUCKET=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw nix_cache_bucket 2>/dev/null)
REGION="$AWS_DEFAULT_REGION"
PROFILE="$DEVENV_ROOT/.devenv/profile"

if [ -z "$BUCKET" ]; then
  echo "Error: could not read nix_cache_bucket. Run tf-apply first." >&2
  exit 1
fi

if [ ! -e "$PROFILE" ]; then
  echo "Devenv profile not built yet. Enter the devenv shell first." >&2
  exit 1
fi

STORE_PATH=$(readlink -f "$PROFILE")
echo "Pushing devenv closure to s3://$BUCKET ..."
nix copy --to "s3://$BUCKET?region=$REGION" "$STORE_PATH"
echo "Done. EC2 will pull store paths from S3 instead of rebuilding."
