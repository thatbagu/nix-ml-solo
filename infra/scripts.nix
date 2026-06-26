_:
{
  scripts = {

    # ── Core ────────────────────────────────────────────────────────────────────
    setup.exec      = builtins.readFile ./scripts/aws/setup.sh;
    status.exec     = builtins.readFile ./scripts/status.sh;
    jupyter.exec    = builtins.readFile ./scripts/jupyter/jupyter.sh;
    logs.exec       = builtins.readFile ./scripts/training/train-logs.sh;

    # ── AWS auth ─────────────────────────────────────────────────────────────────
    aws-login.exec  = builtins.readFile ./scripts/aws/aws-login.sh;
    aws-verify.exec = builtins.readFile ./scripts/aws/aws-verify.sh;

    # ── Terraform / OpenTofu ─────────────────────────────────────────────────────
    tf-bootstrap.exec = builtins.readFile ./scripts/aws/tf-bootstrap.sh;
    tf-init.exec      = builtins.readFile ./scripts/aws/tf-init.sh;
    tf-plan.exec      = builtins.readFile ./scripts/aws/tf-plan.sh;
    tf-apply.exec     = builtins.readFile ./scripts/aws/tf-apply.sh;
    tf-destroy.exec   = builtins.readFile ./scripts/aws/tf-destroy.sh;

    # ── Nix binary cache ─────────────────────────────────────────────────────────
    nix-cache-push.exec            = builtins.readFile ./scripts/nix/nix-cache-push.sh;
    nix-cache-pull.exec            = builtins.readFile ./scripts/nix/nix-cache-pull.sh;
    nix-cache-configure-local.exec = builtins.readFile ./scripts/nix/nix-cache-configure-local.sh;
    nix-sync.exec                  = builtins.readFile ./scripts/nix/nix-sync.sh;

    # ── File sync (EC2 ↔ local via mutagen) ──────────────────────────────────────
    sync.exec            = builtins.readFile ./scripts/sync/sync.sh;
    sync-ec2.exec        = builtins.readFile ./scripts/sync/sync-ec2.sh;
    sync-ec2-status.exec = builtins.readFile ./scripts/sync/sync-ec2-status.sh;
    sync-ec2-stop.exec   = builtins.readFile ./scripts/sync/sync-ec2-stop.sh;
    nixos-rebuild.exec   = builtins.readFile ./scripts/sync/nixos-rebuild.sh;

    # ── MLflow ───────────────────────────────────────────────────────────────────
    mlflow-start.exec = builtins.readFile ./scripts/mlflow/mlflow-start.sh;
    mlflow-open.exec  = builtins.readFile ./scripts/mlflow/mlflow-open.sh;
    mlflow-close.exec = builtins.readFile ./scripts/mlflow/mlflow-close.sh;

    # ── Jupyter ──────────────────────────────────────────────────────────────────
    jupyter-ec2.exec       = builtins.readFile ./scripts/jupyter/jupyter-ec2.sh;
    jupyter-ec2-close.exec = builtins.readFile ./scripts/jupyter/jupyter-ec2-close.sh;

    # ── Training ─────────────────────────────────────────────────────────────────
    train.exec        = builtins.readFile ./scripts/training/train.sh;
    train-on-ec2.exec = builtins.readFile ./scripts/training/train-on-ec2.sh;
    train-status.exec = builtins.readFile ./scripts/training/train-status.sh;
    train-logs.exec   = builtins.readFile ./scripts/training/train-logs.sh;

    # ── Deployment ───────────────────────────────────────────────────────────────
    container-build.exec = builtins.readFile ./scripts/deploy/container-build.sh;
    deploy.exec          = builtins.readFile ./scripts/deploy/deploy.sh;
    deploy-status.exec   = builtins.readFile ./scripts/deploy/deploy-status.sh;

    # ── Lifecycle ────────────────────────────────────────────────────────────────
    teardown.exec = builtins.readFile ./scripts/lifecycle/teardown.sh;
    restore.exec  = builtins.readFile ./scripts/lifecycle/restore.sh;

  };
}
