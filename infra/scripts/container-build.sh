#!/usr/bin/env bash
# Build and push the SageMaker inference image (no Docker daemon).
#
# Tool split:
#   skopeo — pushes the nixpkgs buildLayeredImage tarball (crane can't parse it)
#   crane  — appends the entrypoint layer and ensures Docker manifest format
#
# Layers in ECR (lasagna model):
#   base-<rev>:  one Docker layer per Nix package in the devenv profile
#   latest:      base + entrypoint.sh on top
#
# On devenv.nix changes, only the diff Nix layers are re-pushed.
# SageMaker cold start = Docker pull (parallel, cached) + uv sync (~1-2 min).
set -euo pipefail

# ── nixpkgs pin from devenv.lock ──────────────────────────────────────────────
NIXPKGS_REV=$(python3 -c "
import json; d=json.load(open('$DEVENV_ROOT/devenv.lock'))
print(d['nodes']['nixpkgs']['locked']['rev'])")
NIXPKGS_HASH=$(python3 -c "
import json; d=json.load(open('$DEVENV_ROOT/devenv.lock'))
print(d['nodes']['nixpkgs']['locked']['narHash'])")
SHORT_REV="${NIXPKGS_REV:0:8}"

DEVENV_PROFILE=$(readlink -f "$DEVENV_ROOT/.devenv/profile")
PROFILE_HASH=$(basename "$DEVENV_PROFILE" | cut -c1-8)
EP_HASH=$(sha256sum "$PROJECT_ROOT/infra/container/entrypoint.sh" | cut -c1-8)
BUILD_TAG="build-${PROFILE_HASH}-${EP_HASH}"
ECR_URI=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ecr_repo_uri 2>/dev/null)
ECR_REGISTRY="${ECR_URI%%/*}"

# ── Authenticate both tools to ECR ───────────────────────────────────────────
echo "Authenticating to ECR ($ECR_REGISTRY)..."
ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_DEFAULT_REGION")
echo "$ECR_PASSWORD" | skopeo login --username AWS --password-stdin "$ECR_REGISTRY"
echo "$ECR_PASSWORD" | crane auth login --username AWS --password-stdin "$ECR_REGISTRY"

# ── Build Nix closure image ───────────────────────────────────────────────────
BASE_TAG="$ECR_URI:base-$PROFILE_HASH"
echo "Building Nix closure layers (nixpkgs@${SHORT_REV}, profile: $PROFILE_HASH)..."
BASE_TAR=$(nix-build "$PROJECT_ROOT/infra/container/base.nix" \
  --argstr nixpkgs_rev      "$NIXPKGS_REV" \
  --argstr nixpkgs_nar_hash "$NIXPKGS_HASH" \
  --argstr devenv_profile   "$DEVENV_PROFILE" \
  --no-out-link)

# ── Push Nix layers via skopeo (handles nixpkgs tarball format, pushes Docker v2s2) ──
echo "Pushing Nix layers to $BASE_TAG..."
skopeo copy \
  --format v2s2 \
  "docker-archive:$BASE_TAR" \
  "docker://$BASE_TAG"

# ── Build Python venv layer (baked in — SageMaker VPC has no internet) ───────
echo "Building Python venv (uv sync)..."
VENV_BUILD_DIR=$(mktemp -d /tmp/venv-build.XXXXXX)
VENV_LAYER=$(mktemp /tmp/venv-layer.XXXXXX.tar)
trap 'rm -rf "$VENV_BUILD_DIR" "$VENV_LAYER"' EXIT

UV_PROJECT_ENVIRONMENT="$VENV_BUILD_DIR/venv" \
  uv sync --frozen --no-dev --project "$PROJECT_ROOT"

# Fix shebangs: scripts point to the build-time temp path, rewrite to /venv
find "$VENV_BUILD_DIR/venv/bin" -maxdepth 1 -type f \
  -exec grep -lF "$VENV_BUILD_DIR" {} \; \
  | xargs sed -i "s|$VENV_BUILD_DIR/venv/bin/python|/venv/bin/python|g"

# Pack as a layer — becomes /venv in the container
tar -cf "$VENV_LAYER" -C "$VENV_BUILD_DIR" venv

echo "Appending venv layer → $ECR_URI:with-venv"
crane append \
  --base "$BASE_TAG" \
  -f     "$VENV_LAYER" \
  -t     "$ECR_URI:with-venv"

# ── Append entrypoint layer via crane ────────────────────────────────────────
ENTRYPOINT_LAYER=$(mktemp /tmp/entrypoint-layer.XXXXXX.tar)
trap 'rm -rf "$VENV_BUILD_DIR" "$VENV_LAYER" "$ENTRYPOINT_LAYER"' EXIT

chmod +x "$PROJECT_ROOT/infra/container/entrypoint.sh"
tar --mode=755 -cf "$ENTRYPOINT_LAYER" \
  -C "$PROJECT_ROOT/infra/container" entrypoint.sh

echo "Appending entrypoint layer → $ECR_URI:latest"
crane append \
  --base "$ECR_URI:with-venv" \
  -f     "$ENTRYPOINT_LAYER" \
  -t     "$ECR_URI:latest"

# Set entrypoint and ensure Docker manifest format (crane append produces OCI by default)
crane mutate "$ECR_URI:latest" \
  --entrypoint "/entrypoint.sh"

skopeo copy \
  --format v2s2 \
  "docker://$ECR_URI:latest" \
  "docker://$ECR_URI:latest"

# Stamp this exact build so deploy can skip rebuilding if nothing changed
crane tag "$ECR_URI:latest" "$BUILD_TAG"

echo ""
echo "Done."
echo "  Base (Nix layers) : $BASE_TAG"
echo "  Final image       : $ECR_URI:latest  ($BUILD_TAG)"
