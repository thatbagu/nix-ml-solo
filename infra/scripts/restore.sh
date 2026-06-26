#!/usr/bin/env bash
# Restore MLflow data and DVC after a fresh setup.
# Run this after 'setup' if you have a backup from a previous teardown.
set -euo pipefail

if [ "${INFRA_MODE:-local}" != "cloud" ]; then
  echo "restore requires cloud mode (INFRA_MODE=cloud)." >&2; exit 1
fi

BACKUPS_DIR="$PROJECT_ROOT/backups"
TF_DIR="$PROJECT_ROOT/infra/terraform"

if [ ! -d "$BACKUPS_DIR" ] || [ -z "$(ls -A "$BACKUPS_DIR" 2>/dev/null)" ]; then
  echo "No backups found in $BACKUPS_DIR"
  exit 0
fi

# ── Select backup ─────────────────────────────────────────────────────────────
BACKUPS=$(ls -1t "$BACKUPS_DIR")
SELECTED=$(echo "$BACKUPS" | gum choose --header "Select backup to restore:")

BACKUP_DIR="$BACKUPS_DIR/$SELECTED"
META="$BACKUP_DIR/meta.json"

echo ""
echo "  Backup: $SELECTED"

if [ -f "$META" ]; then
  TIMESTAMP=$(python3 -c "import json; print(json.load(open('$META'))['timestamp'])" 2>/dev/null || echo "unknown")
  GIT_COMMIT=$(python3 -c "import json; print(json.load(open('$META'))['git_commit'])" 2>/dev/null || echo "unknown")
  DVC_PULLED=$(python3 -c "import json; print(json.load(open('$META'))['dvc_pulled'])" 2>/dev/null || echo "false")
  echo "  Date      : $TIMESTAMP"
  echo "  Git commit: $GIT_COMMIT"
  echo "  DVC pulled: $DVC_PULLED"
fi

EC2_IP=$(cd "$TF_DIR" && tofu output -raw ec2_public_ip 2>/dev/null)
SSH="ssh -i $SSH_IDENTITY_FILE -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"

# ── Restore MLflow ────────────────────────────────────────────────────────────
if [ -d "$BACKUP_DIR/mlflow" ]; then
  echo ""
  if gum confirm "  Restore MLflow experiments to EC2?" --default=true; then
    echo "  Pushing MLflow data → ml@$EC2_IP..."

    $SSH "ml@$EC2_IP" "mkdir -p /home/ml/project"

    [ -f "$BACKUP_DIR/mlflow/mlflow.db" ] && \
      rsync -az -e "$SSH" "$BACKUP_DIR/mlflow/mlflow.db" "ml@$EC2_IP:/home/ml/project/"

    [ -d "$BACKUP_DIR/mlflow/mlruns" ] && \
      rsync -az -e "$SSH" "$BACKUP_DIR/mlflow/mlruns/" "ml@$EC2_IP:/home/ml/project/mlruns/"

    echo "  MLflow experiments restored."
  fi
else
  echo "  No MLflow backup found in this snapshot."
fi

# ── Restore DVC ───────────────────────────────────────────────────────────────
if [ "$DVC_PULLED" = "True" ]; then
  echo ""
  if gum confirm "  Push local DVC data back to S3?" --default=true; then
    cd "$PROJECT_ROOT"
    echo "  Pushing DVC data → S3..."
    dvc push
    echo "  DVC data restored."
  fi
fi

echo ""
echo "  ─────────────────────────────────────────────────────────"
echo "  Restore complete."
echo "  ─────────────────────────────────────────────────────────"
