# Introduction

## The problem

Running ML experiments on AWS as a solo practitioner has two failure modes.

**Too much infrastructure**: Kubernetes, Airflow, Argo, Helm charts, a data platform team. You spend more time on infra than on the model.

**Too little infrastructure**: notebooks on a local GPU, experiment results in a CSV, model weights on S3 with no tracking. Works until you need to reproduce a run from three months ago.

nix-ml-solo sits between the two. It gives you MLflow, DVC, SageMaker, and EC2 without the operational overhead — the entire stack fits in one repo and is managed by two people at most: you, and Terraform.

## Philosophy

### One source of truth

`devenv.nix` is the only file you edit to change project-wide configuration. The project name you set there flows into every AWS resource name, every S3 bucket, every script banner. Change `project = "my-experiment"` and `tf-apply` renames everything.

### The same environment everywhere

The Nix closure that builds your local shell is the same one that runs on EC2 and the same one baked into the SageMaker container. There is no "it worked on my machine". If your training script runs locally, it runs on SageMaker.

### Modes instead of branches

Rather than maintaining separate configs for local and cloud, nix-ml-solo uses a single `INFRA_MODE` variable. In `local` mode the tools run on your laptop at no cost. In `cloud` mode the same commands route to EC2 and SageMaker. The switch is one line in `devenv.nix`.

### Reversibility

Teardown is a first-class operation, not an afterthought. Running `teardown` backs up MLflow experiments and offers a DVC pull before destroying anything. After re-provisioning, `restore` puts everything back.
