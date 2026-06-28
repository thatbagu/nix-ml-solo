#!/usr/bin/env bash
# Run once before tf-init to create the S3 state bucket + DynamoDB lock table.
# Vars are taken from TF_VAR_* env (set by devenv) — no var-file needed.
set -euo pipefail

REGION="${TF_VAR_aws_region:-us-east-1}"

# Ensure a default VPC exists — AWS deletes it on new/cleaned accounts and
# Terraform's ec2 module requires it. Safe to run when it already exists.
if ! aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --region "$REGION" \
  --query 'Vpcs[0].VpcId' \
  --output text 2>/dev/null | grep -q "^vpc-"; then
  echo "No default VPC found in ${REGION} — creating one…"
  aws ec2 create-default-vpc --region "$REGION" >/dev/null
  echo "Default VPC created."
fi

cd "$PROJECT_ROOT/infra/terraform/modules/state-bootstrap"
tofu init
tofu apply -auto-approve

echo ""
echo "Bootstrap complete. Now run: tf-init"
