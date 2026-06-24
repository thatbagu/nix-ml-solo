#!/usr/bin/env bash
set -euo pipefail

# ── nixpkgs pin from devenv.lock ──────────────────────────────────────────────
NIXPKGS_REV=$(python3 -c "
import json; d=json.load(open('$DEVENV_ROOT/devenv.lock'))
print(d['nodes']['nixpkgs']['locked']['rev'])")
NIXPKGS_HASH=$(python3 -c "
import json; d=json.load(open('$DEVENV_ROOT/devenv.lock'))
print(d['nodes']['nixpkgs']['locked']['narHash'])")

SHORT_REV="${NIXPKGS_REV:0:8}"

# ── Build Nix base image ──────────────────────────────────────────────────────
echo "Building Nix base image (nixpkgs@${SHORT_REV})..."
BASE_TAR=$(nix-build "$PROJECT_ROOT/infra/container/base.nix" \
  --argstr nixpkgs_rev  "$NIXPKGS_REV" \
  --argstr nixpkgs_nar_hash "$NIXPKGS_HASH" \
  --no-out-link)

docker load < "$BASE_TAR"
BASE_TAG="ml-solo-base:${SHORT_REV}"

# ── Copy uv lockfile into build context ───────────────────────────────────────
cp "$PROJECT_ROOT/pyproject.toml" "$PROJECT_ROOT/infra/container/pyproject.toml"
cp "$PROJECT_ROOT/uv.lock"        "$PROJECT_ROOT/infra/container/uv.lock"
trap 'rm -f "$PROJECT_ROOT/infra/container/pyproject.toml" \
            "$PROJECT_ROOT/infra/container/uv.lock"' EXIT

# ── Build application layer ───────────────────────────────────────────────────
ECR_URI=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ecr_repo_uri 2>/dev/null)

echo "Building application layer..."
docker build \
  --build-arg "BASE_IMAGE=$BASE_TAG" \
  -t "$ECR_URI:latest" \
  "$PROJECT_ROOT/infra/container/"

# ── Push to ECR ───────────────────────────────────────────────────────────────
aws ecr get-login-password --region "$AWS_DEFAULT_REGION" | \
  docker login --username AWS --password-stdin "${ECR_URI%%/*}"

docker push "$ECR_URI:latest"
echo "Pushed $ECR_URI:latest"
