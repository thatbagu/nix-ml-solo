# Getting Started

## Prerequisites

- An AWS account (new accounts work; costs nothing until you run `tf-apply`)
- [devenv](https://devenv.sh/getting-started/) installed (one-liner Nix installer)
- Git

## Step 1 — Get temporary AWS credentials

The setup wizard creates a dedicated IAM user (`<project>-deploy`) automatically. It needs temporary admin access once to do so.

**Root account (brand-new AWS account):**
1. Sign in at [console.aws.amazon.com](https://console.aws.amazon.com)
2. Click your name (top-right) → **Security credentials**
3. **Access keys** → **Create access key** → CLI → copy both values

**Existing IAM admin user:**
IAM → Users → your name → **Security credentials** → **Create access key**

> These credentials are used once to create the `<project>-deploy` user and are never saved to disk.

## Step 2 — Clone and enter the shell

```sh
git clone <repo-url>
cd nix-ml-solo
devenv shell
```

The first `devenv shell` downloads the full Nix closure. This takes a few minutes once; subsequent entries are instant.

## Step 3 — Complete the setup wizard

The wizard fires automatically on first entry. It asks:

| Prompt            | Default     | Notes                                              |
| ----------------- | ----------- | -------------------------------------------------- |
| AWS region        | `us-east-1` | Fuzzy-search from all valid AWS regions            |
| AWS profile       | `ml-solo`   |                                                    |
| Infra mode        | `local`     | `local` = no EC2 cost; `cloud` = full AWS stack    |
| EC2 instance type | `t3.small`  | Cloud mode only                                    |
| Auth method       | IAM keys    | IAM keys (solo) or Identity Center (SSO/teams)     |

At the end the wizard deploys infrastructure (cloud mode) or exits (local mode).

> Run `setup` at any time to reconfigure.

## Step 4 — Run your first training job

```sh
train src/train.py
```

In **local** mode this runs `python src/train.py` directly with MLflow logging to `./mlruns`.

In **cloud** mode it submits a SageMaker training job using the devenv container.

## What's next

- [Configuration](./configuration.md) — customise the project name, ports, and Python deps
- [Local Mode](./local-mode.md) — full workflow without any AWS cost
- [Cloud Mode](./cloud-mode.md) — provision EC2, SageMaker, and S3
