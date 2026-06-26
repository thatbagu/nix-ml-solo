# Teardown & Restore

## Teardown

`teardown` destroys all cloud infrastructure. It backs up data first.

```sh
teardown
```

### What teardown does

1. **Verifies AWS credentials** — exits early with a clear message if credentials are expired or invalid. Run `setup` with fresh bootstrap credentials before retrying.

2. **Backs up MLflow** — SSHes into EC2 and copies `mlflow.db` to `./backups/<timestamp>/mlflow.db`. The backup is local and gitignored.

3. **Offers DVC pull** — prompts whether to pull all DVC-tracked data locally before destroying the S3 bucket. Skip if your data is large and you can re-download it later.

4. **Clears blocking resources** — detaches orphaned Elastic Network Interfaces and drains the ECR repository. These can block `tofu destroy` if not cleared first.

5. **Runs `tofu destroy`** — destroys resources in Terraform state: EC2, ECR, SageMaker, S3 (DVC and Nix cache).

6. **Runs `aws-nuke`** — sweeps any remaining resources outside Terraform state: the `<project>-deploy` IAM user, the S3 state bucket, and the DynamoDB lock table. These were created by the wizard and `tf-bootstrap` and are not in Terraform state.

### After teardown

The AWS account is clean. The S3 state bucket no longer exists.

## Restore

`restore` recovers MLflow experiments and DVC data after re-provisioning a fresh environment.

```sh
tf-bootstrap
tf-init
tf-apply
restore
```

### What restore does

1. **Selects a backup** — shows a list of backups from `./backups/` sorted by date. Uses gum to pick.

2. **Restores MLflow** — SSHes into the new EC2 instance and uploads the selected `mlflow.db`. Restarts the MLflow service.

3. **Pushes DVC data** — runs `dvc push` to upload local data back to the new S3 bucket.

After restore, `mlflow-open` and `status` should show experiments intact.

## Recovery scenarios

### Credentials expired mid-teardown

If teardown fails partway through because credentials expired:

1. Run `setup` to generate new credentials for the `<project>-deploy` IAM user
2. Re-run `teardown` — it's idempotent; already-destroyed resources are skipped

### `aws-nuke` deleted the IAM keys

If you ran an older version or a manual `aws-nuke` that deleted the `<project>-deploy` IAM user before `teardown` could back up:

1. Use root credentials or another IAM admin to run `setup`
2. The wizard creates a new IAM user and access keys
3. Re-run `teardown` with the new credentials

### Teardown succeeded but MLflow backup is missing

If `./backups/` is empty:
- Check whether MLflow was running on EC2 before teardown (`status`)
- MLflow data may have been on an instance that was already stopped

In this case the experiment history is gone. DVC-tracked data in S3 survives teardown only if you chose to pull it locally first (or the S3 bucket was not yet reached by aws-nuke).

### Re-provisioning without a backup

If you're starting fresh with no backup:

```sh
tf-bootstrap
tf-init
tf-apply
# skip restore — enter the shell and start fresh
```
