#!/usr/bin/env bash
set -euo pipefail

BUCKET=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw nix_cache_bucket 2>/dev/null)
REGION="$AWS_DEFAULT_REGION"
STORE_PATH="${1:-}"

if [ -z "$STORE_PATH" ]; then
  echo "Usage: nix-cache-pull /nix/store/<hash>-<name>" >&2
  exit 1
fi

echo "Pulling $STORE_PATH from s3://$BUCKET ..."
nix copy --from "s3://$BUCKET?region=$REGION" --no-check-sigs "$STORE_PATH"
echo "Done."
