# touch privet test2

{ pkgs, lib, ... }:
{
  # infra/devenv.nix adds local-only tooling (terraform, docker, gum wizard, etc.).
  # On EC2 only devenv.nix + devenv.lock are present, so the import is skipped
  # gracefully — devenv evaluates just this file and produces the same environment.
  imports = lib.optional (builtins.pathExists ./infra/devenv.nix) ./infra/devenv.nix;

  # ── Packages ─────────────────────────────────────────────────────────────────
  # Everything here is installed on BOTH local dev and EC2.
  # Add a package once here → it appears everywhere.

  packages = [
    pkgs.awscli2
    pkgs.git
    pkgs.curl
    pkgs.python312
  ];

  languages.python = {
    enable = true;
    uv = {
      enable = true;
      sync.enable = true;
    };
  };

  # ── Env ─────────────────────────────────────────────────────────────────────

  env = {
    MLFLOW_TRACKING_URI = "http://localhost:5000";
    DVC_REMOTE_URL = "s3://nix-ml-solo-dev-dvc/dvc";

    # Switch to "cloud" once infra is deployed to use EC2/SageMaker
    # INFRA_MODE = "cloud";

    # Set your default training script (or pass it to train directly)
    # TRAINING_SCRIPT = "src/train.py";

    # Inference script for cloud deploy — edit src/inference.py to match your model
    INFERENCE_SCRIPT = "src/inference.py";

    TF_VAR_sagemaker_public_endpoint = "true";
  };

  # ── Banner ───────────────────────────────────────────────────────────────────

  enterShell = ''
    source "$DEVENV_ROOT/.venv/bin/activate" 2>/dev/null || true
    MODE="''${INFRA_MODE:-local}"
    echo ""
    echo "  nix-ml-solo  [mode: $MODE]"
    echo "  ─────────────────────────────────────────────"
    echo "    setup                   configure AWS + deploy infrastructure"
    echo "    train <script|notebook> run training job"
    echo "    deploy <run-id>         deploy model to endpoint"
    echo "    status                  show what's running"
    echo "    jupyter                 open JupyterLab"
    echo "    logs <job>              stream training logs"
    echo "    teardown                destroy all cloud infrastructure"
    echo "    restore                 restore MLflow + DVC from backup"
    if [ "$MODE" = "cloud" ]; then
    echo "    sync                    manually sync files + Nix cache + EC2"
    fi
    echo "  ─────────────────────────────────────────────"
    echo ""
  '';
}
