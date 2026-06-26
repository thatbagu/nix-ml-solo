#!/usr/bin/env bash
# Tear down all cloud infrastructure.
# Backs up MLflow data from EC2 and offers DVC pull, then destroys everything.
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud

TF_DIR="$PROJECT_ROOT/infra/terraform"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
BACKUP_DIR="$PROJECT_ROOT/backups/$(date +%Y-%m-%d-%H%M%S)"

DVC_BUCKET=$(cd "$TF_DIR" && tofu output -raw dvc_bucket_name 2>/dev/null)
EC2_IP=$(cd "$TF_DIR" && tofu output -raw ec2_public_ip 2>/dev/null || true)

_s3_size() {
  aws s3 ls "s3://$1" --recursive --human-readable --summarize \
    --region "$REGION" 2>/dev/null \
    | grep "Total Size" | sed 's/.*Total Size: //' || echo "unknown"
}

echo ""
echo "  ─────────────────────────────────────────────────────────"
echo "  teardown — destroys ALL cloud infrastructure"
echo "  ─────────────────────────────────────────────────────────"
echo ""
echo "  Calculating S3 storage sizes..."
DVC_SIZE=$(_s3_size "$DVC_BUCKET")

echo ""
echo "  DVC data (s3://$DVC_BUCKET): $DVC_SIZE"
echo "  Nix cache: regenerable — skipping"
echo ""

# ── Backup MLflow from EC2 ────────────────────────────────────────────────────
DVC_PULLED=false

if [ -n "$EC2_IP" ] && [ -n "${SSH_IDENTITY_FILE:-}" ] && [ -f "${SSH_IDENTITY_FILE}" ]; then
  echo "  Backing up MLflow data from EC2..."
  mkdir -p "$BACKUP_DIR/mlflow"
  SSH="ssh -i $SSH_IDENTITY_FILE -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"

  $SSH "ml@$EC2_IP" \
    "tar czf - -C /home/ml mlflow.db mlflow.db-shm mlflow.db-wal 2>/dev/null" \
    | tar xzf - -C "$BACKUP_DIR/mlflow/" 2>/dev/null || true

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
  > "$BACKUP_DIR/meta.json"

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
mutagen sync terminate nix-ml-solo 2>/dev/null || true

echo "  Closing SSH tunnels..."
pkill -f "ssh.*5000:localhost:5000" 2>/dev/null || true
pkill -f "ssh.*8888:localhost:8888" 2>/dev/null || true

# ── Destroy ───────────────────────────────────────────────────────────────────
echo ""
echo "  Destroying infrastructure..."
cd "$TF_DIR"
tofu destroy -auto-approve

echo ""
echo "  ─────────────────────────────────────────────────────────"
echo "  Done. Cloud infrastructure destroyed."
echo "  Backup: $BACKUP_DIR"
echo "  Run 'setup' to provision again, then 'restore' to recover data."
echo "  ─────────────────────────────────────────────────────────"
