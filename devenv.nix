{ pkgs, ... }: {
  imports = [ ./infra/devenv.nix ];

  # ── ML / DS packages ────────────────────────────────────────────────────────

  packages = [ pkgs.git pkgs.curl ];

  languages.python = {
    enable  = true;
    version = "3.12";
    uv = {
      enable      = true;
      sync.enable = true;
    };
  };

  # ── Env ─────────────────────────────────────────────────────────────────────

  env = {
    MLFLOW_TRACKING_URI = "http://localhost:5000";
    DVC_REMOTE_URL      = "s3://nix-ml-solo-dev-dvc/dvc";

    # Switch to "cloud" once infra is deployed to use EC2/SageMaker
    # INFRA_MODE = "cloud";

    # Set your default training script (or pass it to train directly)
    # TRAINING_SCRIPT = "src/train.py";

    # Inference script for cloud deploy — edit src/inference.py to match your model
    INFERENCE_SCRIPT = "src/inference.py";
  };

  # ── Banner ───────────────────────────────────────────────────────────────────

  enterShell = ''
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
    echo "    nix-cache-push          push local closure → S3"
    echo "    nix-cache-pull          pull specific path ← S3"
    echo "  ─────────────────────────────────────────────"
    echo ""
  '';
}
