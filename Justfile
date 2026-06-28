set shell := ["bash", "-euo", "pipefail", "-c"]

# Show available recipes
_default:
    @just --list

# ── Core ──────────────────────────────────────────────────────────────────────

# Run the interactive setup wizard (AWS credentials, SSH keys, project config)
setup:
    setup

# Show current infrastructure status
status:
    status

# Start JupyterLab locally
jupyter:
    jupyter

# Show training logs (optional job name)
logs job="":
    logs {{job}}

# ── AWS auth ──────────────────────────────────────────────────────────────────

# Login to AWS (SSO or IAM)
aws-login:
    aws-login

# Verify AWS credentials are valid
aws-verify:
    aws-verify

# ── Terraform / OpenTofu ──────────────────────────────────────────────────────

# Bootstrap Terraform state backend (S3 bucket + DynamoDB lock table)
tf-bootstrap:
    tf-bootstrap

# Initialize Terraform working directory
tf-init:
    tf-init

# Show Terraform execution plan
tf-plan:
    tf-plan

# Apply Terraform changes
tf-apply:
    tf-apply

# Destroy all Terraform-managed resources
tf-destroy:
    tf-destroy

# ── Nix binary cache ──────────────────────────────────────────────────────────

# Push a Nix store path to the S3 binary cache
nix-cache-push:
    nix-cache-push

# Pull a specific path from the S3 binary cache
nix-cache-pull path:
    nix-cache-pull {{path}}

# Configure a local Nix binary cache (for faster rebuilds)
nix-cache-configure-local:
    nix-cache-configure-local

# Sync Nix packages from local cache to S3
nix-sync:
    nix-sync

# ── File sync (EC2 ↔ local via mutagen) ──────────────────────────────────────

# Start local file sync session
sync:
    sync

# Start bidirectional sync with EC2
sync-ec2:
    sync-ec2

# Show EC2 sync status
sync-ec2-status:
    sync-ec2-status

# Stop EC2 sync session
sync-ec2-stop:
    sync-ec2-stop

# Run nixos-rebuild on EC2
nixos-rebuild:
    nixos-rebuild

# ── MLflow ────────────────────────────────────────────────────────────────────

# Start MLflow tracking server locally
mlflow-start:
    mlflow-start

# Open SSH tunnel to MLflow on EC2
mlflow-open:
    mlflow-open

# Close MLflow SSH tunnel
mlflow-close:
    mlflow-close

# ── Jupyter ───────────────────────────────────────────────────────────────────

# Open SSH tunnel to JupyterLab on EC2
jupyter-ec2:
    jupyter-ec2

# Close JupyterLab SSH tunnel
jupyter-ec2-close:
    jupyter-ec2-close

# ── Training ──────────────────────────────────────────────────────────────────

# Run a training script (locally or on SageMaker depending on INFRA_MODE)
train *args:
    train {{args}}

# Run a training script directly on EC2 via SSH
train-on-ec2 *args:
    train-on-ec2 {{args}}

# Show SageMaker training job status
train-status job="":
    train-status {{job}}

# Stream SageMaker training job logs
train-logs job="":
    train-logs {{job}}

# ── Deployment ────────────────────────────────────────────────────────────────

# Build and push the inference container image to ECR
container-build:
    container-build

# Deploy a trained model (local: mlflow serve; cloud: SageMaker endpoint)
deploy run-id artifact="model":
    uv run python infra/scripts/py/deploy.py {{run-id}} {{artifact}}

# Show SageMaker endpoint status
deploy-status:
    deploy-status

# ── Lifecycle ─────────────────────────────────────────────────────────────────

# Backup MLflow + DVC, then destroy all cloud infrastructure
teardown:
    uv run python infra/scripts/py/teardown.py

# Restore MLflow experiments and DVC data after a fresh setup
restore:
    uv run python infra/scripts/py/restore.py
