# Commands

Eight commands cover the ML lifecycle. Lower-level commands are available as escape hatches.

## Core commands

| Command                         | Description                                          |
|---------------------------------|------------------------------------------------------|
| `setup`                         | Configure AWS credentials and deploy infrastructure  |
| `status`                        | Show what's running (EC2, MLflow, Jupyter, endpoint) |
| `train <script\|notebook>`      | Run a training job                                   |
| `deploy <run-id>`               | Package a model and deploy to endpoint               |
| `jupyter`                       | Open JupyterLab                                      |
| `logs <job-name>`               | Stream SageMaker training logs                       |
| `teardown`                      | Destroy all cloud infrastructure (backs up first)    |
| `restore`                       | Recover MLflow + DVC after re-provisioning           |

## Infrastructure commands

| Command         | Description                                              |
|-----------------|----------------------------------------------------------|
| `tf-bootstrap`  | Create S3 state bucket + DynamoDB lock table (once)     |
| `tf-init`       | Initialise OpenTofu with the S3 backend                  |
| `tf-plan`       | Preview what Terraform will create/change/destroy        |
| `tf-apply`      | Apply the Terraform plan                                 |

## AWS commands

| Command         | Description                                              |
|-----------------|----------------------------------------------------------|
| `aws-login`     | Refresh SSO credentials (Identity Center auth only)     |
| `aws-verify`    | Print the current caller identity                        |

## Sync commands

| Command              | Description                                         |
|----------------------|-----------------------------------------------------|
| `sync`               | Start file sync + push Nix cache + open MLflow tunnel |
| `sync-ec2-status`    | Show mutagen session status                         |
| `sync-ec2-stop`      | Stop the mutagen session                            |
| `nixos-rebuild`      | Push a NixOS config change to EC2 without replacing it |
| `nix-sync`           | Push devenv closure to S3 Nix cache                 |
| `nix-cache-push`     | Push a specific store path to the S3 cache          |
| `nix-cache-pull`     | Pull a specific store path from the S3 cache        |

## MLflow commands

| Command          | Description                                            |
|------------------|--------------------------------------------------------|
| `mlflow-start`   | Start local MLflow server                              |
| `mlflow-open`    | Open SSH tunnel to EC2 MLflow (cloud mode)             |
| `mlflow-close`   | Close the MLflow SSH tunnel                            |

## Training commands

| Command              | Description                                         |
|----------------------|-----------------------------------------------------|
| `train-on-ec2 <script>` | Run training on EC2 directly (no SageMaker quota) |
| `train-status [job]`  | Show SageMaker job status                          |
| `train-logs <job>`    | Stream CloudWatch logs for a job                  |

## Jupyter commands

| Command                | Description                                       |
|------------------------|---------------------------------------------------|
| `jupyter-ec2-close`    | Close JupyterLab tunnel and stop server on EC2    |

## Deploy commands

| Command              | Description                                         |
|----------------------|-----------------------------------------------------|
| `deploy-status`      | Show SageMaker endpoint status and URL              |
| `container-build`    | Build and push the SageMaker container image        |
