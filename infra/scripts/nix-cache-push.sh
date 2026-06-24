#!/usr/bin/env bash
set -euo pipefail

BUCKET=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw nix_cache_bucket 2>/dev/null)
REGION="$AWS_DEFAULT_REGION"

if [ -z "$BUCKET" ]; then
  echo "Error: could not read nix_cache_bucket from terraform output. Run tf-apply first." >&2
  exit 1
fi

PROFILE_PATH=$(nix build .#mlEnv --print-out-paths --no-link 2>/dev/null || echo "")
if [ -z "$PROFILE_PATH" ]; then
  PROFILE_PATH=$(nix build --print-out-paths --no-link 2>/dev/null)
fi

echo "Pushing closure of $PROFILE_PATH to s3://$BUCKET ..."
nix copy --to "s3://$BUCKET?region=$REGION" "$PROFILE_PATH"
echo "Done."
