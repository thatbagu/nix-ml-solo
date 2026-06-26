# nix-ml-solo

Solo ML stack on AWS. Reproducible environments via Nix, experiment tracking via MLflow, data versioning via DVC, training on EC2 or SageMaker.

## What it gives you

- **One command to start**: `devenv shell` installs every tool, configures AWS, and opens MLflow.
- **Two modes**: work locally for free, flip one line to switch to EC2/SageMaker.
- **Reproducible everywhere**: the same Nix closure runs on your laptop, on EC2, and inside the SageMaker container.
- **Safe teardown**: backs up MLflow and DVC data before destroying anything.

## Quick links

- [Getting Started](./getting-started.md) — from zero to first training run
- [Configuration](./configuration.md) — how `devenv.nix` drives everything
- [Commands](./commands.md) — full reference for all commands
- [FAQ](./faq.md) — common problems and fixes
