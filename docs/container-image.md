# Container Image

## Overview

`container-build` builds the SageMaker training and inference container image without a Docker daemon. It uses Nix to produce deterministic OCI layers and pushes them to ECR.

```sh
container-build    # build and push to ECR (called automatically by train/deploy)
```

## Why no Docker daemon

Nix's `buildLayeredImage` produces a deterministic OCI image tarball directly from the Nix store. This removes the need for a running Docker daemon and makes the build reproducible — the same `devenv.lock` always produces the same image layers.

## Image layer structure (lasagna model)

```
ECR image: <project>-<env>:latest
├── Layer N:   entrypoint.sh
├── Layer N-1: Python venv (/venv — from uv sync --frozen)
├── Layer 2:   Nix package B  ┐
├── Layer 1:   Nix package A  ├─ one layer per package in devenv profile
└── Layer 0:   Nix store base ┘
```

The Nix layers are tagged `base-<profile-hash>` in ECR. If `devenv.nix` changes but only two packages differ, only two layers are re-pushed — the rest are already in ECR and are reused by content hash.

## Build tools

Two tools handle the push because their capabilities differ:

| Tool    | Role                                                          |
|---------|---------------------------------------------------------------|
| skopeo  | Pushes the nixpkgs `buildLayeredImage` tarball (Docker v2s2 format) |
| crane   | Appends the venv layer and entrypoint layer; converts OCI → Docker manifest format |

skopeo handles the Nix tarball format that crane can't parse. crane handles layer appending and manifest mutation.

## Layers in detail

### Nix closure layers

`base.nix` calls `pkgs.dockerTools.buildLayeredImage` with the devenv profile as input. Each Nix package becomes its own Docker layer. The nixpkgs revision and devenv profile hash are passed as arguments so the layer tags are stable and deterministic.

### Python venv layer

`uv sync --frozen --no-dev` runs into a temp directory. The resulting venv is packed as a tar layer and appended at `/venv` in the image. Script shebangs pointing at the temp build path are rewritten to `/venv/bin/python`.

The venv is baked in (not downloaded at runtime) because SageMaker training containers run in a VPC with no internet access.

### Entrypoint layer

`infra/container/entrypoint.sh` is appended as a single layer and set as the container `CMD`. It activates the venv, sets environment variables, and calls the training script.

## Rebuild conditions

`container-build` stamps a build tag (`build-<profile-hash>-<entrypoint-hash>`) in ECR. The `train` and `deploy` commands check whether this tag exists before deciding to rebuild. If nothing changed, the push is skipped entirely.

## ECR authentication

`container-build` authenticates both skopeo and crane to ECR using a temporary password from `aws ecr get-login-password`. No credentials are stored on disk.
