# nix-ml-solo

Solo ML stack on AWS. Reproducible environments via Nix, experiment tracking via MLflow, data versioning via DVC, training on EC2 or SageMaker.

## From zero to first run

### Step 1 — Create an AWS account

Go to [aws.amazon.com](https://aws.amazon.com) → **Create an AWS Account**. Nothing is charged until you deploy infrastructure.

### Step 2 — Get temporary credentials for the setup wizard

The wizard creates a dedicated IAM user automatically. It needs temporary admin access once.

**Root account (brand-new account):**

1. Sign in at [console.aws.amazon.com](https://console.aws.amazon.com)
2. Click your name (top-right) → **Security credentials**
3. **Access keys** → **Create access key** → CLI → copy both values

**Existing IAM admin user:** IAM → Users → your name → **Security credentials** → **Create access key**

> These credentials are used once and never saved to disk.

### Step 3 — Install devenv

Follow [devenv.sh/getting-started](https://devenv.sh/getting-started/) — a one-liner Nix installer.

### Step 4 — Clone and enter the shell

```sh
git clone <this-repo>
cd nix-ml-solo
devenv shell
```

The setup wizard fires on first run. It asks for:

| Prompt            | Default     | Notes                                              |
| ----------------- | ----------- | -------------------------------------------------- |
| AWS region        | `us-east-1` | Fuzzy-search from all valid AWS regions            |
| AWS profile       | `ml-solo`   |                                                    |
| Infra mode        | `local`     | `local` = laptop only, no EC2 cost                 |
| EC2 instance type | `t3.small`  | Cloud mode only                                    |
| Auth method       | IAM keys    | IAM keys (solo) or IAM Identity Center (SSO/teams) |

Project name and environment are set in `devenv.nix` — not asked here.  
SSH keypair is auto-generated at `~/.ssh/<project>` in cloud mode.  
Settings are re-used on every subsequent shell. Run `setup` to reconfigure.

## Configuring your project

`devenv.nix` is the single source of truth. Change values here and they flow everywhere — Terraform resource names, S3 bucket names, script banners, ports.

```nix
let
  project      = "nix-ml-solo";   # → all AWS resource names
  environment  = "dev";
  mlflowPort   = 5000;
  jupyterPort  = 8888;
  inferencePort = 5001;
in
{ ... }
```

To switch to cloud mode, uncomment one line:

```nix
# env.INFRA_MODE = "cloud";
```

## First-time infra setup (cloud mode)

The setup wizard offers to deploy infrastructure at the end of first run. To run manually:

```sh
tf-bootstrap       # create S3 state bucket + DynamoDB lock table (once)
tf-init            # initialise OpenTofu with the S3 backend
tf-plan            # review what will be created
tf-apply           # provision everything (~5 min)
```

This creates:

- **EC2** — NixOS VM running MLflow (SSH tunnel, no public port)
- **S3** — DVC data bucket + Nix binary cache bucket
- **ECR** — container registry for training/inference images
- **SageMaker** — inference endpoint (off by default, enable with `TF_VAR_sagemaker_public_endpoint`)
- **VPC endpoints** — ECR + S3 gateway so SageMaker containers can pull images without internet

> **SageMaker training quotas**: new AWS accounts have all SageMaker training instance quotas set to 0. Either request a quota increase in the Service Quotas console or use `train-on-ec2` to run training directly on the EC2 VM instead.

## Core commands

Eight commands cover the full ML lifecycle. Everything else is automatic.

```sh
setup                           # configure AWS credentials + deploy infra
status                          # show EC2 / sync / MLflow / Jupyter / endpoint state

train src/train.py              # run training (.py or .ipynb)
train notebooks/exp.ipynb
train src/train.py -- --lr 0.01
deploy <mlflow-run-id>          # package model → endpoint

jupyter                         # open JupyterLab (local or EC2 tunnel)
logs <job-name>                 # stream SageMaker training logs

teardown                        # destroy all cloud infra (backs up MLflow first)
restore                         # recover MLflow + DVC after re-deploying
```

In **cloud mode**, `train` and `deploy` automatically:

- Start the file sync session if it is not running
- Open the MLflow SSH tunnel if it is not open
- Build and push the container image if it has changed

The `sync` command is available as a manual escape hatch if you need to force a sync outside of train/deploy.

## Two modes

|           | `local` (default)             | `cloud`                           |
| --------- | ----------------------------- | --------------------------------- |
| MLflow    | runs on your machine          | runs on EC2, SSH tunnel           |
| Training  | `python script.py` directly   | SageMaker job (or `train-on-ec2`) |
| Inference | `mlflow models serve` locally | SageMaker endpoint                |
| AWS cost  | S3 only (~$0)                 | EC2 + SageMaker + ECR             |

## Training on EC2 vs SageMaker

Two cloud training paths:

**`train <script>`** — submits a SageMaker training job. Requires a quota increase for training instance types (all zero by default in new accounts). Runs in a Docker container built from your devenv.

**`train-on-ec2 <script>`** — SSH into the EC2 VM and runs the script there directly in the devenv shell. No quota required, uses the same instance as MLflow. Good for testing before requesting SageMaker quotas.

## Inference endpoint

Edit `src/inference.py` (implements `model_fn` / `predict_fn` / `input_fn` / `output_fn` for MLflow pyfunc) and run:

```sh
deploy <mlflow-run-id>
```

`deploy` will:

1. Open the MLflow tunnel if needed
2. Auto-build the container if devenv or entrypoint changed
3. Download model artifacts from MLflow
4. Package them as `model.tar.gz` with the inference script
5. Upload to S3 and create/update the SageMaker endpoint via Terraform

To expose the endpoint publicly (no AWS auth):

```nix
# devenv.nix
env.TF_VAR_sagemaker_public_endpoint = "true";
```

Then `tf-apply` and `deploy-status` will print the public HTTPS URL.

## Teardown

`teardown` destroys all cloud infrastructure safely:

1. Backs up MLflow database from EC2
2. Offers to pull DVC data locally
3. Clears orphaned ENIs and drains the ECR repo
4. Runs `tofu destroy` for ordered state-managed deletion
5. Runs `aws-nuke` to sweep any remaining resources (wizard IAM user, state bucket, etc.)

After teardown, re-provisioning requires:

```sh
tf-bootstrap       # state bucket was nuked — recreate it
tf-init
tf-apply
restore            # recover MLflow experiments + push DVC data back
```

## Customising the EC2 VM

The VM runs NixOS. Add packages or services without touching the Terraform module:

```nix
# devenv.nix
env.TF_VAR_ec2_extra_nix_config = ''
  environment.systemPackages = with pkgs; [ htop ripgrep ];
  services.prometheus.enable = true;
'';
```

Then `tf-plan && tf-apply` to apply, or `nixos-rebuild` to push without replacing the instance.

## AWS auth

### IAM user keys (default, solo use)

The wizard automates this end-to-end. It creates `<project>-deploy` with `AdministratorAccess` and writes the keys to `.devenv-configs/.aws/credentials`.

### IAM Identity Center / SSO (teams)

1. Enable **IAM Identity Center** in your AWS account
2. Create a user and assign the `AdministratorAccess` permission set
3. Note your **SSO start URL** (e.g. `https://my-org.awsapps.com/start`)
4. Enter the URL, account ID, and role name in the setup wizard
5. Run `aws-login` when credentials expire

## Project structure

```
nix-ml-solo/
├── devenv.nix              # single source of truth: project, env, ports
├── pyproject.toml          # Python dependencies (managed by uv)
├── src/
│   ├── train.py            # starter training script
│   └── inference.py        # SageMaker inference handler
├── notebooks/
│   └── starter.ipynb       # full loop: load → train → log → deploy
└── infra/
    ├── devenv.nix          # infra tooling (tofu, gum, mutagen, aws-nuke)
    ├── scripts.nix         # devenv script definitions (routing table)
    ├── scripts/
    │   ├── _lib.sh         # shared guards + helpers
    │   ├── _wizard.sh      # first-time setup wizard
    │   ├── enter-shell.sh  # shell entrypoint
    │   ├── aws/            # setup, aws-login, tf-bootstrap/init/plan/apply/destroy
    │   ├── sync/           # sync-ec2, nixos-rebuild, nix-sync
    │   ├── mlflow/         # mlflow-start/open/close
    │   ├── jupyter/        # jupyter-ec2, tunnel management
    │   ├── training/       # train, train-on-ec2, train-status, train-logs
    │   ├── deploy/         # container-build, deploy, deploy-status
    │   ├── nix/            # nix-cache-push/pull/configure
    │   └── lifecycle/      # teardown, restore
    └── terraform/
        └── modules/
            ├── ec2/                # NixOS VM, IAM roles, SG, VPC endpoints
            ├── s3/                 # DVC data bucket
            ├── nix-cache/          # Nix binary cache bucket + IAM policies
            ├── sagemaker/          # inference endpoint + autoscaling
            ├── sagemaker-training/ # ECR repo
            ├── api-gateway-inference/ # public HTTPS wrapper (optional)
            └── state-bootstrap/    # S3 state bucket + DynamoDB (run once)
```
