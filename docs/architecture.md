# Architecture

## One environment, three materializations

The central idea in nix-ml-solo is that `devenv.nix` defines a single Nix environment that is materialized in three places simultaneously — your laptop, the EC2 VM, and the SageMaker container. Four sync channels keep them consistent:

| Channel | Syncs | Mechanism |
|---|---|---|
| **Files** | laptop ↔ EC2 | mutagen bidirectional sync over SSH |
| **Packages** | laptop → S3 → EC2 / SageMaker | Nix binary cache in S3 |
| **Experiments** | SageMaker → EC2 ← laptop | MLflow server on EC2, SSH tunnel locally |
| **Data** | laptop ↔ S3 ↔ SageMaker | DVC remote on S3 |

This eliminates the "works on my machine" problem for ML: if your training script runs locally, it runs on SageMaker, because the Nix closure that produced the environment is bit-for-bit identical.

## C4 Container diagram

```mermaid
C4Container
    title nix-ml-solo: one Nix environment, three materializations

    Person(engineer, "ML Engineer", "Solo practitioner")

    System_Boundary(env, "Unified environment - defined once in devenv.nix") {
        Container(local, "Local shell", "devenv, Nix, Python, uv", "Development, experiments, all commands")
        Container(ec2, "EC2 NixOS VM", "NixOS", "MLflow server, SSH endpoint, remote training")
        Container(sagemaker, "SageMaker container", "OCI, same Nix closure + venv", "Training jobs, inference endpoint")
    }

    ContainerDb(nix_cache, "Nix binary cache", "S3", "Pre-built store paths shared by all three runtimes")
    ContainerDb(mlflow_db, "MLflow", "SQLite on EC2 EBS", "Experiments, runs, model registry")
    ContainerDb(dvc_store, "DVC store", "S3", "Versioned training datasets and artifacts")
    Container(ecr, "ECR", "Container registry", "Image layers: Nix closure + Python venv + entrypoint")

    Rel(engineer, local, "devenv shell / commands", "fish / bash")
    Rel(local, ec2, "mutagen file sync", "SSH")
    Rel(ec2, local, "mutagen file sync", "SSH")
    Rel(local, ec2, "MLflow SSH tunnel", "port 5000")
    Rel(local, nix_cache, "nix-sync: push devenv closure", "s3://")
    Rel(ec2, nix_cache, "nixos-rebuild: pull packages", "s3://")
    Rel(local, ecr, "container-build: push layers", "skopeo + crane")
    Rel(sagemaker, ecr, "pull image on job start", "HTTPS")
    Rel(local, mlflow_db, "log metrics + artifacts", "HTTP via tunnel")
    Rel(sagemaker, mlflow_db, "log training metrics", "HTTP")
    Rel(local, dvc_store, "dvc push / pull", "s3://")
    Rel(sagemaker, dvc_store, "dvc pull training data", "s3://")
```

## Why this works

### Nix makes the environment portable

The devenv shell, the NixOS EC2 image, and the SageMaker container are all built from the same `devenv.lock`. Nix computes a content-addressed hash for each package; the same hash always produces the same binary. There are no version strings or floating tags — the lock file is the environment.

### The Nix binary cache eliminates redundant builds

When you update `devenv.nix` and run `direnv reload`, Nix builds the new packages locally. `nix-sync` pushes the resulting store paths to S3. When EC2 runs `nixos-rebuild`, it pulls pre-built paths from S3 instead of compiling from source. The SageMaker container layers are also stamped by the devenv profile hash — unchanged layers are reused directly from ECR.

### mutagen replaces a shared filesystem

EC2 sees your project files as if they were local because mutagen syncs them in real time over SSH. This means you can edit locally and run `train-on-ec2` without an explicit `rsync` step, and output files written on EC2 appear locally immediately.

### MLflow on EC2 with an SSH tunnel

MLflow runs as a service on EC2. `mlflow-open` creates a local SSH tunnel on port 5000, so `MLFLOW_TRACKING_URI=http://localhost:5000` works the same whether the code is running locally or inside a SageMaker job. There is no public MLflow port — the tunnel is the only entry point.
