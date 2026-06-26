#!/usr/bin/env bash
# Generates backend config from TF_VAR_* env vars and runs tofu init.
# Terraform backend blocks don't support variable interpolation, so we pass
# values via -backend-config instead.
set -euo pipefail

PROJECT="${TF_VAR_project:-nix-ml-solo}"
ENV="${TF_VAR_environment:-dev}"
REGION="${TF_VAR_aws_region:-us-east-1}"

BACKEND_CFG="$PROJECT_ROOT/infra/terraform/backend.tfvars"

cat >"$BACKEND_CFG" <<EOF
bucket         = "${PROJECT}-${ENV}-tfstate"
key            = "${PROJECT}/terraform.tfstate"
region         = "${REGION}"
dynamodb_table = "${PROJECT}-${ENV}-tfstate-lock"
encrypt        = true
EOF

cd "$PROJECT_ROOT/infra/terraform"
tofu init -backend-config="$BACKEND_CFG" "$@"
