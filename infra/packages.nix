# All operational scripts as writeShellApplication derivations.
# Each script gets: shellcheck at build time, pinned runtime deps,
# and a Nix store path installable system-wide on NixOS EC2.
{ pkgs }:

let
  # SC1090/SC1091: dynamic source paths via $PROJECT_ROOT are intentional.
  noSc = [ "SC1090" "SC1091" ];

  mk = name: src: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      excludeShellChecks = noSc;
      text = builtins.readFile src;
    };

  # Python scripts: thin bash wrapper that delegates to uv run python.
  pyMk = name: runtimeInputs:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      excludeShellChecks = noSc;
      text = ''exec uv run python "$PROJECT_ROOT/infra/scripts/py/${name}.py" "$@"'';
    };
in
[
  # ── Core ────────────────────────────────────────────────────────────────────
  (mk "setup" ./scripts/aws/setup.sh [ pkgs.bash pkgs.gum pkgs.awscli2 ])
  (mk "status" ./scripts/status.sh [ pkgs.awscli2 pkgs.curl pkgs.mutagen pkgs.tenv ])
  (mk "jupyter" ./scripts/jupyter/jupyter.sh [ ])
  (mk "logs" ./scripts/training/train-logs.sh [ pkgs.awscli2 ])

  # ── AWS auth ─────────────────────────────────────────────────────────────────
  (mk "aws-login" ./scripts/aws/aws-login.sh [ pkgs.awscli2 ])
  (mk "aws-verify" ./scripts/aws/aws-verify.sh [ pkgs.awscli2 ])

  # ── Terraform / OpenTofu ─────────────────────────────────────────────────────
  (mk "tf-bootstrap" ./scripts/aws/tf-bootstrap.sh [ pkgs.awscli2 pkgs.tenv ])
  (mk "tf-init" ./scripts/aws/tf-init.sh [ pkgs.tenv ])
  (mk "tf-plan" ./scripts/aws/tf-plan.sh [ pkgs.tenv ])
  (mk "tf-apply" ./scripts/aws/tf-apply.sh [ pkgs.tenv ])
  (mk "tf-destroy" ./scripts/aws/tf-destroy.sh [ pkgs.tenv ])

  # ── Nix binary cache ─────────────────────────────────────────────────────────
  (mk "nix-cache-push" ./scripts/nix/nix-cache-push.sh [ pkgs.awscli2 pkgs.tenv ])
  (mk "nix-cache-pull" ./scripts/nix/nix-cache-pull.sh [ pkgs.awscli2 pkgs.tenv ])
  (mk "nix-cache-configure-local" ./scripts/nix/nix-cache-configure-local.sh [ pkgs.tenv ])
  (mk "nix-sync" ./scripts/nix/nix-sync.sh [ pkgs.awscli2 pkgs.tenv ])

  # ── File sync (EC2 ↔ local via mutagen) ──────────────────────────────────────
  (mk "sync" ./scripts/sync/sync.sh [ pkgs.mutagen pkgs.tenv ])
  (mk "sync-ec2" ./scripts/sync/sync-ec2.sh [ pkgs.mutagen pkgs.openssh pkgs.tenv ])
  (mk "sync-ec2-status" ./scripts/sync/sync-ec2-status.sh [ pkgs.mutagen ])
  (mk "sync-ec2-stop" ./scripts/sync/sync-ec2-stop.sh [ pkgs.mutagen ])
  (mk "nixos-rebuild" ./scripts/sync/nixos-rebuild.sh [ pkgs.openssh pkgs.tenv ])

  # ── MLflow ───────────────────────────────────────────────────────────────────
  (mk "mlflow-start" ./scripts/mlflow/mlflow-start.sh [ ])
  (mk "mlflow-open" ./scripts/mlflow/mlflow-open.sh [ pkgs.openssh pkgs.tenv ])
  (mk "mlflow-close" ./scripts/mlflow/mlflow-close.sh [ pkgs.openssh ])

  # ── Jupyter ──────────────────────────────────────────────────────────────────
  (mk "jupyter-ec2" ./scripts/jupyter/jupyter-ec2.sh [ pkgs.openssh pkgs.tenv ])
  (mk "jupyter-ec2-close" ./scripts/jupyter/jupyter-ec2-close.sh [ pkgs.openssh ])

  # ── Training ─────────────────────────────────────────────────────────────────
  (mk "train" ./scripts/training/train.sh [ pkgs.awscli2 pkgs.curl pkgs.mutagen pkgs.tenv ])
  (mk "train-on-ec2" ./scripts/training/train-on-ec2.sh [ pkgs.openssh pkgs.tenv ])
  (mk "train-status" ./scripts/training/train-status.sh [ pkgs.awscli2 ])
  (mk "train-logs" ./scripts/training/train-logs.sh [ pkgs.awscli2 ])

  # ── Deployment ───────────────────────────────────────────────────────────────
  (mk "container-build" ./scripts/deploy/container-build.sh [ pkgs.awscli2 pkgs.python3 pkgs.skopeo pkgs.crane pkgs.tenv ])
  (pyMk "deploy" [ pkgs.awscli2 pkgs.curl pkgs.tenv pkgs.uv ])
  (mk "deploy-status" ./scripts/deploy/deploy-status.sh [ pkgs.awscli2 pkgs.curl ])

  # ── Lifecycle ────────────────────────────────────────────────────────────────
  (pyMk "teardown" [ pkgs.awscli2 pkgs.gum pkgs.mutagen pkgs.aws-nuke pkgs.tenv pkgs.uv ])
  (pyMk "restore" [ pkgs.awscli2 pkgs.gum pkgs.openssh pkgs.tenv pkgs.uv ])
]
