#!/usr/bin/env bash
# Tear down all cloud infrastructure.
# Backs up MLflow data from EC2 and offers DVC pull, then destroys everything.
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud

# Verify AWS credentials are alive before proceeding.
# If they're dead (e.g. aws-nuke deleted keys in a prior run), warn and exit early.
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "" >&2
  echo "  Error: AWS credentials are invalid or expired." >&2
  echo "  Run 'setup' to generate fresh credentials, then re-run teardown." >&2
  echo "" >&2
  exit 1
fi

TF_DIR="$PROJECT_ROOT/infra/terraform"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
BACKUP_DIR="$PROJECT_ROOT/backups/$(date +%Y-%m-%d-%H%M%S)"

DVC_BUCKET=$(cd "$TF_DIR" && tofu output -raw dvc_bucket_name 2>/dev/null || true)
EC2_IP=$(cd "$TF_DIR" && tofu output -raw ec2_public_ip 2>/dev/null || true)

_s3_size() {
  aws s3 ls "s3://$1" --recursive --human-readable --summarize \
    --region "$REGION" 2>/dev/null |
    grep "Total Size" | sed 's/.*Total Size: //' || echo "unknown"
}

echo ""
echo "  ─────────────────────────────────────────────────────────"
echo "  teardown — destroys ALL cloud infrastructure"
echo "  ─────────────────────────────────────────────────────────"
echo ""
if [ -n "$DVC_BUCKET" ]; then
  echo "  Calculating S3 storage sizes..."
  DVC_SIZE=$(_s3_size "$DVC_BUCKET")
else
  DVC_SIZE="unknown (state already destroyed)"
fi

echo ""
echo "  DVC data (s3://${DVC_BUCKET:-<unknown>}): $DVC_SIZE"
echo "  Nix cache: regenerable — skipping"
echo ""

# ── Backup MLflow from EC2 ────────────────────────────────────────────────────
DVC_PULLED=false

if [ -n "$EC2_IP" ] && [ -n "${SSH_IDENTITY_FILE:-}" ] && [ -f "${SSH_IDENTITY_FILE}" ]; then
  echo "  Backing up MLflow data from EC2..."
  mkdir -p "$BACKUP_DIR/mlflow"
  SSH="ssh -i $SSH_IDENTITY_FILE -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"

  $SSH "ml@$EC2_IP" \
    "tar czf - -C /home/ml mlflow.db mlflow.db-shm mlflow.db-wal 2>/dev/null" |
    tar xzf - -C "$BACKUP_DIR/mlflow/" 2>/dev/null || true

  MLFLOW_SIZE=$(du -sh "$BACKUP_DIR/mlflow/" 2>/dev/null | cut -f1 || echo "0")
  echo "  MLflow backed up → $BACKUP_DIR/mlflow/  ($MLFLOW_SIZE)"
else
  echo "  Skipping MLflow backup (EC2 not reachable)."
fi

# ── Offer DVC pull ────────────────────────────────────────────────────────────
echo ""
if gum confirm "  Download DVC data locally before destroying? ($DVC_SIZE)" --default=false; then
  echo ""
  echo "  Pulling DVC data → $PROJECT_ROOT ..."
  cd "$PROJECT_ROOT" && uv run dvc pull
  DVC_PULLED=true
  echo "  DVC data saved locally."
fi

# ── Save backup metadata ──────────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"
jq -n \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg dvc_bucket "$DVC_BUCKET" \
  --arg ec2_ip "${EC2_IP:-}" \
  --argjson dvc_pulled "$DVC_PULLED" \
  --arg git_commit "$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")" \
  '{timestamp: $timestamp, dvc_bucket: $dvc_bucket, ec2_ip: $ec2_ip, dvc_pulled: $dvc_pulled, git_commit: $git_commit}' \
  >"$BACKUP_DIR/meta.json"

echo ""
echo "  Backup saved → $BACKUP_DIR"
echo "  Run 'restore' after your next setup to recover MLflow experiments"
if $DVC_PULLED; then
  echo "  and push DVC data back with 'dvc push'."
fi

# ── Final confirmation ────────────────────────────────────────────────────────
echo ""
gum style \
  --border double --border-foreground 196 \
  --padding "1 4" \
  "  WARNING: this will destroy EC2, SageMaker, ECR, S3, and all related resources.  "
echo ""

if ! gum confirm "  Confirm: destroy everything?" --default=false; then
  echo "Aborted."
  exit 0
fi

# ── Stop background processes ─────────────────────────────────────────────────
echo ""
echo "  Stopping file sync..."
mutagen sync terminate "${TF_VAR_project:-nix-ml-solo}" 2>/dev/null || true

echo "  Closing SSH tunnels..."
pkill -f "ssh.*${MLFLOW_PORT:-5000}:localhost:${MLFLOW_PORT:-5000}" 2>/dev/null || true
pkill -f "ssh.*${JUPYTER_PORT:-8888}:localhost:${JUPYTER_PORT:-8888}" 2>/dev/null || true

# ── Destroy ───────────────────────────────────────────────────────────────────
# VPC interface endpoints (ECR API/DKR) and SageMaker model endpoints both
# create ENIs attached to the sagemaker SG. AWS removes them asynchronously
# after resource deletion — if we let tofu destroy everything at once it hits
# the SG before ENIs are gone and fails with DependencyViolation.
# Fix: pre-destroy the ENI-creating resources in order, poll until ENIs are
# released, then run the full destroy which will find the SG already free.

PROJECT="${TF_VAR_project:-nix-ml-solo}"
ENV="${TF_VAR_environment:-dev}"

echo ""
echo "  Destroying infrastructure..."

# Record the sagemaker SG id now so we can poll for ENI release later.
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${PROJECT}-${ENV}-sagemaker-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text --region "$REGION" 2>/dev/null || echo "")

# Step 1: remove SageMaker endpoint + model (they create ENIs via vpc_config)
echo "  [1/3] removing SageMaker endpoint..."
(cd "$TF_DIR" && tofu destroy -auto-approve \
  -target "module.sagemaker[0].aws_sagemaker_endpoint.endpoint[0]" \
  -target "module.sagemaker[0].aws_sagemaker_endpoint_configuration.config[0]" \
  -target "module.sagemaker[0].aws_sagemaker_model.model[0]") 2>/dev/null || true

# Step 2: remove ECR VPC interface endpoints (each creates ENIs in the same SG)
echo "  [2/3] removing VPC interface endpoints..."
(cd "$TF_DIR" && tofu destroy -auto-approve \
  -target "module.ec2[0].aws_vpc_endpoint.ecr_api" \
  -target "module.ec2[0].aws_vpc_endpoint.ecr_dkr") 2>/dev/null || true

# Step 3: clear ENIs from the security group.
# VPC endpoint / SageMaker ENIs are removed asynchronously by AWS. If a
# previous partial destroy left one orphaned (available state, no owner),
# we delete it directly — AWS won't clean it up on its own.
if [ -n "${SG_ID:-}" ] && [ "$SG_ID" != "None" ]; then
  echo "  [3/3] clearing ENIs from $SG_ID..."
  for i in $(seq 1 24); do
    ENIS=$(aws ec2 describe-network-interfaces \
      --filters "Name=group-id,Values=$SG_ID" \
      --query 'NetworkInterfaces[*].{Id:NetworkInterfaceId,Status:Status}' \
      --output json --region "$REGION" 2>/dev/null || echo "[]")

    ENI_COUNT=$(echo "$ENIS" | jq 'length')
    [ "${ENI_COUNT:-0}" -eq 0 ] && {
      echo "  ENIs cleared."
      break
    }

    # Delete any available (orphaned) ENIs immediately rather than waiting.
    echo "$ENIS" | jq -r '.[] | select(.Status=="available") | .Id' |
      while read -r ENI_ID; do
        [ -z "$ENI_ID" ] && continue
        echo "  Deleting orphaned ENI $ENI_ID..."
        aws ec2 delete-network-interface \
          --network-interface-id "$ENI_ID" --region "$REGION" 2>/dev/null || true
      done

    printf "  %s ENI(s) in-use — waiting for AWS cleanup (%s/24)…\r" "$ENI_COUNT" "$i"
    sleep 15
  done
fi

# Step 4: drain ECR images (force_delete=true only applies after the next apply).
# Name is deterministic — don't rely on tofu output which may be stale mid-destroy.
ECR_REPO="${PROJECT}-${ENV}-ml"
IMAGE_IDS=$(aws ecr list-images \
  --repository-name "$ECR_REPO" --region "$REGION" \
  --query 'imageIds' --output json 2>/dev/null || echo "[]")
if [ "$IMAGE_IDS" != "[]" ] && [ "$IMAGE_IDS" != "null" ]; then
  echo "  [4/4] draining ECR repo $ECR_REPO..."
  aws ecr batch-delete-image \
    --repository-name "$ECR_REPO" --region "$REGION" \
    --image-ids "$IMAGE_IDS" >/dev/null
fi

# Terraform destroy — handles ordered deletion of state-managed resources.
# Run with || true: aws-nuke below is the guarantee, not tofu.
echo "  Destroying terraform-managed resources..."
(cd "$TF_DIR" && tofu destroy -auto-approve) || true

# ── aws-nuke: catch everything terraform missed ───────────────────────────────
# Covers orphaned ENIs, wizard-created IAM users, state backend bucket, and
# anything else that slips through partial destroys or manual intervention.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -n "$ACCOUNT_ID" ] && command -v aws-nuke &>/dev/null; then
  echo ""
  echo "  Running aws-nuke sweep..."

  # aws-nuke v3 requires an account alias to proceed (safety gate).
  # Create one scoped to this project if none exists.
  aws iam create-account-alias --account-alias "${PROJECT}" 2>/dev/null || true

  # Exclude the IAM user running this script — aws-nuke would otherwise delete
  # its own access keys mid-run, causing all subsequent API calls to fail with
  # InvalidAccessKeyId and leaving the S3 state bucket and the user itself behind.
  CALLER_USER=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null |
    sed 's|.*/||' || echo "")

  NUKE_CONFIG=$(mktemp --suffix=.yaml)
  cat >"$NUKE_CONFIG" <<YAML
regions:
  - ${REGION}
  - global

blocklist:
  - "000000000000"

accounts:
  "${ACCOUNT_ID}":
    filters:
      IAMUser:
        - "root"
        - "${CALLER_USER}"
      IAMUserAccessKey:
        - type: "regex"
          value: "^${CALLER_USER} -> .*"
      IAMUserPolicyAttachment:
        - type: "regex"
          value: "^${CALLER_USER} -> .*"
YAML

  aws-nuke run \
    --config "$NUKE_CONFIG" \
    --no-dry-run \
    --force \
    2>&1 | grep -Ev "^(Scan|aws-nuke version|No resource|time=)" || true

  rm -f "$NUKE_CONFIG"

  # Now that nuke is done (and the deploy user still has valid credentials),
  # delete the wizard-created IAM user explicitly as the final step.
  DEPLOY_USER="${PROJECT}-deploy"
  if aws iam get-user --user-name "$DEPLOY_USER" >/dev/null 2>&1; then
    echo "  Deleting IAM user $DEPLOY_USER..."
    # Detach policies
    aws iam list-attached-user-policies --user-name "$DEPLOY_USER" \
      --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null |
      tr '\t' '\n' | while read -r arn; do
      [ -z "$arn" ] && continue
      aws iam detach-user-policy --user-name "$DEPLOY_USER" --policy-arn "$arn" 2>/dev/null || true
    done
    # Delete access keys
    aws iam list-access-keys --user-name "$DEPLOY_USER" \
      --query 'AccessKeyMetadata[*].AccessKeyId' --output text 2>/dev/null |
      tr '\t' '\n' | while read -r key; do
      [ -z "$key" ] && continue
      aws iam delete-access-key --user-name "$DEPLOY_USER" --access-key-id "$key" 2>/dev/null || true
    done
    aws iam delete-user --user-name "$DEPLOY_USER" 2>/dev/null || true
    echo "  IAM user $DEPLOY_USER deleted."
  fi
fi

echo ""
echo "  ─────────────────────────────────────────────────────────"
echo "  Done. Cloud infrastructure destroyed."
echo "  Backup: $BACKUP_DIR"
echo "  Run 'setup' to provision again, then 'restore' to recover data."
echo "  Note: re-run 'tf-bootstrap' before 'tf-apply' (state bucket was nuked)."
echo "  ─────────────────────────────────────────────────────────"
