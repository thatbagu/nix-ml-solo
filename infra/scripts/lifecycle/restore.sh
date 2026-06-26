#!/usr/bin/env bash
# Restore MLflow data and DVC after a fresh setup.
# Run this after 'setup' if you have a backup from a previous teardown.
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud
_require_ssh

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

DVC_PULLED=false
if [ -f "$META" ]; then
  TIMESTAMP=$(jq -r '.timestamp // "unknown"' "$META" 2>/dev/null || echo "unknown")
  GIT_COMMIT=$(jq -r '.git_commit // "unknown"' "$META" 2>/dev/null || echo "unknown")
  DVC_PULLED=$(jq -r '.dvc_pulled // false' "$META" 2>/dev/null || echo "false")
  echo "  Date      : $TIMESTAMP"
  echo "  Git commit: $GIT_COMMIT"
  echo "  DVC pulled: $DVC_PULLED"
fi

EC2_IP=$(cd "$TF_DIR" && tofu output -raw ec2_public_ip 2>/dev/null)
SSH="ssh -i $SSH_IDENTITY_FILE -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"

# ── Restore MLflow ────────────────────────────────────────────────────────────
if [ -d "$BACKUP_DIR/mlflow" ] && [ -n "$(ls -A "$BACKUP_DIR/mlflow" 2>/dev/null)" ]; then
  echo ""
  if gum confirm "  Restore MLflow experiments to EC2?" --default=true; then
    echo "  Pushing MLflow data → ml@$EC2_IP..."
    tar czf - -C "$BACKUP_DIR/mlflow" . |
      $SSH "ml@$EC2_IP" "tar xzf - -C /home/ml/"
    echo "  MLflow experiments restored."
  fi
else
  echo "  No MLflow backup found in this snapshot."
fi

# ── Restore DVC ───────────────────────────────────────────────────────────────
if [ "$DVC_PULLED" = "true" ]; then
  echo ""
  if gum confirm "  Push local DVC data back to S3?" --default=true; then
    cd "$PROJECT_ROOT"
    echo "  Pushing DVC data → S3..."
    uv run dvc push
    echo "  DVC data pushed."
  fi
fi

echo ""
echo "  ─────────────────────────────────────────────────────────"
echo "  Restore complete."
echo "  ─────────────────────────────────────────────────────────"
