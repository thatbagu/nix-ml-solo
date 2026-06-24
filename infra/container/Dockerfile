# Base: nix-community's flakes-enabled image — Nix + nix-command + flakes pre-configured.
# Pinned to stable channel. To use unstable: FROM nixpkgs/nix-flakes:latest
FROM nixpkgs/nix-flakes:nixos-25.05

# Install uv and awscli2 via Nix — stays in the Nix ecosystem, no pip/apt.
RUN nix profile install nixpkgs#uv nixpkgs#awscli2 && \
    nix-collect-garbage -d

WORKDIR /app

# Copy dependency manifest first so Docker layer-caches the install
# when only source code changes.
COPY pyproject.toml uv.lock* ./

# Install production deps only — exact versions from lockfile, no dev tools.
# --frozen ensures uv.lock is never auto-updated inside the image.
# --no-dev excludes ipykernel, black, ruff, etc.
RUN uv sync --frozen --no-dev

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SageMaker Training:  entrypoint execs the training script via uv run
# SageMaker Inference: entrypoint starts the model server via uv run
ENTRYPOINT ["/entrypoint.sh"]
