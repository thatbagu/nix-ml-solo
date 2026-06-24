# Base is built from pinned nixpkgs (same commit as devenv.lock) via base.nix.
# Run container-build — it builds the Nix base first, then this Dockerfile on top.
ARG BASE_IMAGE=ml-solo-base:latest
FROM ${BASE_IMAGE}

WORKDIR /app

# Copy dependency manifests first so Docker caches this layer when only
# source code changes.
COPY pyproject.toml uv.lock* ./

# Install production deps only — exact versions from uv.lock, no dev tools.
RUN uv sync --frozen --no-dev

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
