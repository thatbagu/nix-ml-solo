# touch
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
  };

  # ── Banner ───────────────────────────────────────────────────────────────────

  enterShell = ''
    # Auto-sync devenv closure to S3 when the profile changes (cloud mode only).
    # .devenv/profile is a symlink whose target changes on every rebuild.
    _STAMP="$DEVENV_ROOT/.devenv-configs/.last-synced-profile"
    _CUR=$(readlink -f "$DEVENV_ROOT/.devenv/profile" 2>/dev/null || true)
    _PREV=$(cat "$_STAMP" 2>/dev/null || true)
    if [ -n "$_CUR" ] && [ "$_CUR" != "$_PREV" ] && [ "''${INFRA_MODE:-local}" = "cloud" ]; then
      echo "devenv profile changed — syncing closure to S3…"
      nix-sync && echo "$_CUR" > "$_STAMP"
    fi
    unset _STAMP _CUR _PREV

    MODE="''${INFRA_MODE:-local}"
    echo ""
    echo "  nix-ml-solo  [mode: $MODE]"
    echo "  ─────────────────────────────────────────────"
    echo "  ML"
    echo "    jupyter lab             start notebook"
    echo "    open notebooks/starter.ipynb to get started"
    echo "    dvc pull / dvc push     sync data with S3"
    echo ""
    if [ "$MODE" = "local" ]; then
    echo "  Local"
    echo "    mlflow-start            start MLflow server (localhost:5000)"
    echo "    train <script.py|.ipynb>  run training locally"
    echo "    deploy <run-id>         serve model locally (localhost:5001)"
    echo "    deploy-status           check local inference server"
    else
    echo "  Cloud (AWS)"
    echo "    mlflow-open             SSH tunnel → MLflow on EC2"
    echo "    train <script.py|.ipynb>  submit SageMaker training job"
    echo "    train-on-ec2 <script>   submit from EC2 via SSH"
    echo "    train-status [job]      check job status"
    echo "    train-logs <job>        stream CloudWatch logs"
    echo "    deploy <run-id>         package + deploy SageMaker endpoint"
    echo "    deploy-status           check endpoint status"
    echo "    container-build         build + push to ECR"
    fi
    echo ""
    echo "  AWS"
    echo "    aws-login               authenticate"
    echo "    aws-verify              confirm identity"
    echo "    setup                   re-run setup wizard"
    echo ""
    echo "  Terraform"
    echo "    tf-bootstrap            create S3 state bucket (run once)"
    echo "    tf-init / tf-plan / tf-apply / tf-destroy"
    echo ""
    echo "  Nix cache"
    echo "    nix-sync                push devenv closure → S3 (EC2 pulls, no rebuild)"
    echo "    nix-cache-push          push arbitrary closure → S3"
    echo "    nix-cache-pull          pull specific path ← S3"
    echo "  ─────────────────────────────────────────────"
    echo ""
  '';
}
