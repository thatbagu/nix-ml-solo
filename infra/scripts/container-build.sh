#!/usr/bin/env bash
set -euo pipefail

ECR_URI=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ecr_repo_uri 2>/dev/null)
REGION="$AWS_DEFAULT_REGION"

# Copy uv lockfile into the build context so the Dockerfile can run uv sync --frozen.
# The lockfile lives at the project root; the Dockerfile is in infra/container/.
cp "$PROJECT_ROOT/pyproject.toml" "$PROJECT_ROOT/infra/container/pyproject.toml"
cp "$PROJECT_ROOT/uv.lock"        "$PROJECT_ROOT/infra/container/uv.lock"
trap 'rm -f "$PROJECT_ROOT/infra/container/pyproject.toml" "$PROJECT_ROOT/infra/container/uv.lock"' EXIT

echo "Building container..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_URI"

docker build -t "$ECR_URI:latest" "$PROJECT_ROOT/infra/container"

docker push "$ECR_URI:latest"
echo "Pushed $ECR_URI:latest"
