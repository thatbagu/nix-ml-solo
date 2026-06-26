#!/usr/bin/env bash
# Run once before tf-init to create the S3 state bucket + DynamoDB lock table.
# Vars are taken from TF_VAR_* env (set by devenv) — no var-file needed.
set -euo pipefail

cd "$PROJECT_ROOT/infra/terraform/modules/state-bootstrap"
tofu init
tofu apply -auto-approve

echo ""
echo "Bootstrap complete. Now run: tf-init"
