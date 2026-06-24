# nix-ml-solo

Solo ML stack on AWS. Reproducible environments via Nix, experiment tracking via MLflow, data versioning via DVC, training via SageMaker.

## Prerequisites

- [Nix](https://nixos.org/download) with flakes enabled
- [devenv](https://devenv.sh/getting-started/)
- AWS account — see [AWS auth setup](#aws-auth-setup) below

## Quick start

```sh
git clone <this-repo>
cd nix-ml-solo
devenv shell
```

On first run the setup wizard fires automatically. It will ask for:

| Prompt | Default | Notes |
|---|---|---|
| Project name | `nix-ml-solo` | Used to name all AWS resources |
| AWS region | `us-east-1` | |
| AWS profile | `ml-solo` | |
| SSH public key | `~/.ssh/id_ed25519.pub` | Auto-read if present |
| EC2 instance type | `t3.medium` | |
| Auth method | IAM keys | IAM keys or IAM Identity Center (SSO) |

Press Enter to accept any default. Settings are saved to `.devenv-configs/local.env` (gitignored) and re-used on every subsequent `devenv shell`.

## First-time infra setup

The setup wizard offers to deploy infrastructure automatically at the end of first run. If you skipped it, run manually:

```sh
tf-bootstrap       # create S3 state bucket + DynamoDB lock table
tf-init            # initialise Terraform with the S3 backend
tf-plan            # review what will be created
tf-apply           # provision everything
```

This creates:
- **EC2** — NixOS VM running MLflow (SSH tunnel access only)
- **S3** — DVC data bucket + Nix binary cache bucket + Terraform state bucket
- **ECR** — container registry for training/inference images
- **SageMaker** — training job config (inference endpoint off by default)

## Two modes

Set `INFRA_MODE` in `devenv.nix` (or choose during setup wizard):

| | `local` (default) | `cloud` |
|---|---|---|
| MLflow | runs on your machine | runs on EC2, SSH tunnel |
| Training | `python script.py` directly | SageMaker job |
| Inference | `mlflow models serve` on localhost | SageMaker endpoint |
| AWS infra needed | S3 only | EC2 + SageMaker + ECR |

```nix
# devenv.nix — switch to cloud
env.INFRA_MODE = "cloud";
```

## Day-to-day

```sh
# Data (both modes)
dvc pull                    # pull latest data from S3
dvc push                    # push new data to S3
jupyter lab                 # start notebook

# Local mode
mlflow-start                # start MLflow on localhost:5000
train src/train.py          # run training script locally
train notebooks/starter.ipynb     # run notebook via papermill
train src/train.py -- --lr 0.01   # with extra args
train notebooks/starter.ipynb -- -p lr 0.01  # papermill parameters
deploy <run-id>             # serve model on localhost:5001
deploy-status               # check local server

# Cloud mode
mlflow-open                 # SSH tunnel → MLflow on EC2
train src/train.py          # submit SageMaker job (.py or .ipynb)
train-status [job]          # check job status
train-logs <job>            # stream CloudWatch logs
train-on-ec2 src/train.py   # submit from EC2 via SSH
deploy <run-id>             # package model → SageMaker endpoint
deploy-status               # check endpoint status
container-build             # build + push to ECR
```

## Inference script

For cloud deploys, SageMaker needs an inference script alongside the model weights. Copy the template and point devenv at it:

```sh
Edit `src/inference.py` — it's already there as a starter.
```

```nix
# devenv.nix
env.INFERENCE_SCRIPT = "src/inference.py";
```

The template implements `model_fn` / `input_fn` / `predict_fn` / `output_fn` using `mlflow.pyfunc`. Edit to match your model flavour (sklearn, pytorch, etc.) and input/output format.

`deploy <run-id>` then:
1. Fetches model artifacts from MLflow by run ID
2. Places `inference.py` under `code/` inside `model.tar.gz`
3. Uploads to S3
4. Creates/updates the SageMaker endpoint via Terraform

## Starter notebook

`notebooks/starter.ipynb` shows the full loop — load data, train with MLflow tracking, log the model, push data with DVC, deploy. Works in both local and cloud mode.

## Customising the EC2 VM

The VM runs NixOS. Add packages, services, or any NixOS module attributes by setting `TF_VAR_ec2_extra_nix_config` in the root `devenv.nix` — no need to touch the Terraform module:

```nix
# devenv.nix
{ pkgs, ... }: {
  imports = [ ./infra/devenv.nix ];
  # ...

  env.TF_VAR_ec2_extra_nix_config = ''
    environment.systemPackages = with pkgs; [ htop ripgrep ];
    services.prometheus.enable = true;
  '';
}
```

Then apply:

```sh
tf-plan
tf-apply
```

## AWS auth setup

The setup wizard asks which method you want. Both are supported:

### Option 1 — IAM user access keys (recommended for solo use)

The setup wizard automates this fully. It will:

1. Ask for temporary **bootstrap credentials** (your root account keys or an existing admin user — used once, not saved)
2. Create a dedicated IAM user `<project>-deploy`
3. Attach `AdministratorAccess` (or a scoped policy — your choice)
4. Generate access keys and write them to `.devenv-configs/.aws/credentials`

You only need the AWS console once to get the bootstrap credentials:
- **Root account**: AWS Console → top-right account menu → Security credentials → Access keys
- **Existing admin user**: IAM → Users → your user → Security credentials → Create access key

Reference: [AWS — Managing access keys for IAM users](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)

### Option 2 — IAM Identity Center (SSO, recommended for teams)

Shorter-lived credentials, centralised access control across team members.

1. Enable **IAM Identity Center** in your AWS account
2. Create a user and assign the `AdministratorAccess` permission set
3. Note your **SSO start URL** (e.g. `https://my-org.awsapps.com/start`)
4. Enter the URL, account ID, and role name in the setup wizard
5. Run `aws-login` to open the browser auth flow

Reference: [AWS — Getting started with IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/getting-started.html)

---

## Re-run setup

```sh
setup              # wipes local.env and re-runs the wizard
```

## Project structure

```
nix-ml-solo/
├── devenv.nix          # DS entry point — Python, uv, ML packages
├── pyproject.toml      # Python dependencies (managed by uv)
└── infra/
    ├── devenv.nix      # AWS, Terraform, devenv scripts
    ├── scripts.nix     # all devenv script definitions
    ├── scripts/        # shell scripts called by devenv
    ├── terraform/      # OpenTofu modules
    │   └── modules/
    │       ├── ec2/             # NixOS VM + MLflow
    │       ├── s3/              # DVC data bucket
    │       ├── nix-cache/       # Nix binary cache bucket
    │       ├── sagemaker/       # inference endpoint (off by default)
    │       ├── sagemaker-training/  # ECR + training job config
    │       └── state-bootstrap/ # S3 state bucket (run once)
    └── container/      # Dockerfile + entrypoint for SageMaker
```
