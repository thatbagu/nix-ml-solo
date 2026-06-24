# nix-ml-solo

Solo ML stack on AWS. Reproducible environments via Nix, experiment tracking via MLflow, data versioning via DVC, training via SageMaker.

## From zero to first run

If you're new to AWS, follow these four steps — the setup wizard handles everything after step 2.

### Step 1 — Create an AWS account

Go to [aws.amazon.com](https://aws.amazon.com) → **Create an AWS Account**. A credit card is required but nothing is charged until you deploy infrastructure. If it is your first time creating aws account, you would be most likely offered free trial of 200 USD.

### Step 2 — Get temporary credentials for the setup wizard

The wizard will create a dedicated IAM user for you automatically. To do that it needs temporary admin access once.

**Root account (simplest for a brand-new account):**

1. Sign in at [console.aws.amazon.com](https://console.aws.amazon.com)
2. Click your account name (top-right) → **Security credentials**
3. Scroll to **Access keys** → **Create access key** → choose **Command Line Interface**
4. Copy the **Access Key ID** and **Secret Access Key** — you'll paste them into the wizard

**Existing IAM admin user:**

1. IAM → Users → your username → **Security credentials** tab
2. **Create access key** → Command Line Interface → copy both values

> These credentials are used once by the wizard and never saved to disk.

### Step 3 — Install devenv

Follow [devenv.sh/getting-started](https://devenv.sh/getting-started/) — a one-liner Nix installer.

### Step 4 — Clone and run

```sh
git clone <this-repo>
cd nix-ml-solo
devenv shell
```

The setup wizard fires on first run. Press Enter to accept defaults shown in `[brackets]`. It will:

- Ask for project name, AWS region, infra mode (local vs cloud)
- Use your bootstrap credentials to create an IAM user `<project>-deploy` with its own keys
- Write everything to `.devenv-configs/local.env` (gitignored, never committed)

| Prompt            | Default       | Notes                                              |
| ----------------- | ------------- | -------------------------------------------------- |
| Project name      | `nix-ml-solo` | Used to name all AWS resources; must be lowercase  |
| AWS region        | `us-east-1`   | Fuzzy-search from all valid AWS regions            |
| AWS profile       | `ml-solo`     |                                                    |
| Infra mode        | `local`       | `local` = laptop only, no EC2 cost                 |
| EC2 instance type | `t3.micro`    | Cloud mode only; free-tier eligible, good for MLflow |
| Auth method       | IAM keys      | IAM keys (solo) or IAM Identity Center (SSO/teams) |

SSH keypair is auto-generated at `~/.ssh/<project-name>` in cloud mode — no paste needed.

Settings are re-used on every subsequent `devenv shell`. Run `setup` anytime to reconfigure.

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

|                  | `local` (default)                  | `cloud`                 |
| ---------------- | ---------------------------------- | ----------------------- |
| MLflow           | runs on your machine               | runs on EC2, SSH tunnel |
| Training         | `python script.py` directly        | SageMaker job           |
| Inference        | `mlflow models serve` on localhost | SageMaker endpoint      |
| AWS infra needed | S3 only                            | EC2 + SageMaker + ECR   |

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

The setup wizard supports two methods:

### Option 1 — IAM user access keys (default, good for solo use)

The wizard automates this fully — see [Step 2](#step-2--get-temporary-credentials-for-the-setup-wizard) above for where to get the bootstrap credentials. It will:

1. Create a dedicated IAM user `<project>-deploy`
2. Attach `AdministratorAccess` (or a scoped policy — your choice)
3. Generate access keys and write them to `.devenv-configs/.aws/credentials`

Reference: [AWS — Managing access keys for IAM users](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)

### Option 2 — IAM Identity Center (SSO, for teams)

Shorter-lived credentials, centralised access control.

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
