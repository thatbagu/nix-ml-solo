# FAQ

## Setup

### The setup wizard doesn't show anything / exits silently

The wizard uses gum TUI components that require an interactive terminal. If you're running `setup` from inside a non-interactive context, it may exit silently. `setup` uses `exec bash -i` internally to get an interactive shell — if your terminal emulator strips the TTY, try running from a plain terminal rather than an embedded one.

### The wizard runs on every shell entry

This means a previous wizard run didn't complete. The wizard saves its output to `.devenv-configs/local.env`. If the file is missing or empty, the wizard re-runs.

Run `setup` to force a fresh wizard run that completes properly.

### `setup` says "AWS credentials are invalid"

You're using IAM access keys that have been deleted or expired. This happens if a previous `teardown` ran `aws-nuke` and deleted the `<project>-deploy` IAM user.

Use your root account or another IAM admin to get temporary credentials, then run `setup` to create a new IAM user.

---

## Training

### `train` fails with `ResourceLimitExceeded` or quota error

New AWS accounts have all SageMaker training instance quotas set to 0. Request an increase:

1. AWS console → **Service Quotas** → **Amazon SageMaker**
2. Find the quota for your instance type (e.g. `ml.m5.large for training job usage`)
3. Request an increase (takes minutes to hours)

While waiting, use `train-on-ec2 <script>` to run directly on the EC2 instance.

### Training job succeeds but nothing appears in MLflow

The SageMaker container needs to reach the MLflow server. In cloud mode, MLflow runs on EC2 and the container connects via the private VPC endpoint or SSH tunnel. Check:

1. The MLflow tunnel is open: `mlflow-open`
2. `MLFLOW_TRACKING_URI` is set correctly in the container environment

### Notebook training fails with papermill errors

Ensure the cell you want papermill to inject parameters into is tagged `parameters`. In JupyterLab: select the cell → **Property Inspector** (right panel) → **Tags** → type `parameters` and press Enter.

---

## Infrastructure

### `tf-apply` fails with "bucket already exists"

The S3 state bucket name must be globally unique. If another account or region already has `<project>-<env>-tfstate`, change the project or environment name in `devenv.nix` and re-run `tf-bootstrap`.

### `tf-apply` fails with "ENI still attached"

A network interface from a previous deployment is blocking deletion. Run `teardown` which handles ENI cleanup automatically, or manually detach the ENI in the EC2 console.

### EC2 instance first boot takes 5-15 minutes

NixOS bootstraps from scratch on first launch. The `mlflow-open` command retries until the SSH port is available — just leave it running. Subsequent boots (stop/start) take under a minute.

---

## Sync

### Mutagen shows "halted" or "waiting for rescan"

Stop and restart the sync session:

```sh
sync-ec2-stop
sync
```

### Files are not appearing on EC2

Check that the mutagen session is in "Watching" state:

```sh
sync-ec2-status
```

If the EC2 IP changed (instance was restarted), run `sync` again — it regenerates the SSH config entry with the new IP and restarts the session.

---

## Container

### Container build fails with "manifest unknown"

The ECR repository doesn't have the base image yet. Run `container-build` directly:

```sh
container-build
```

### Container build is slow on first run

The first build pushes the full Nix closure layer by layer. Subsequent builds only push changed layers (those not already in ECR by content hash). The Nix binary cache in S3 also helps — run `nix-sync` before `container-build` if you've updated `devenv.nix`.

---

## Teardown

### Teardown fails with credentials error

The `<project>-deploy` IAM keys have been deleted (possibly by a previous partial teardown). Run `setup` with bootstrap credentials to get new keys, then re-run `teardown`.

### aws-nuke is deleting resources from other projects

aws-nuke filters by resource tags and the project name. It targets only resources tagged with `Project=<project>`. Check that no other resources in your account share the same tag value.

---

## Nix

### `direnv reload` takes a long time

The first reload after changing `devenv.nix` builds any new packages. Subsequent reloads use the Nix store cache. If you've pushed the closure to S3 previously, ensure `nix-cache-configure-local` has been run so Nix pulls from S3 instead of rebuilding.

### "experimental features" error when running `nix` commands

The devenv shell sets `NIX_CONFIG` to enable flakes and nix-command. If you're running `nix` outside the devenv shell, add to `~/.config/nix/nix.conf`:

```
experimental-features = nix-command flakes
```
