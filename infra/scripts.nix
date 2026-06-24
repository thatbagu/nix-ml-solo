_:
{
  scripts = {

    # ── Setup ───────────────────────────────────────────────────────────────

    setup.exec = ''
      rm -f "$DEVENV_ROOT/.devenv-configs/local.env"
      exec "$DEVENV_ROOT/infra/scripts/enter-shell.sh"
    '';

    # ── AWS auth ────────────────────────────────────────────────────────────

    aws-login.exec = ''
      case "''${AWS_AUTH_METHOD:-iam}" in
        sso)
          echo "Logging in via IAM Identity Center (profile: $AWS_PROFILE)..."
          aws sso login --profile "$AWS_PROFILE"
          echo "Done. Run 'aws-verify' to confirm."
          ;;
        iam)
          echo "Using IAM access keys — no login needed."
          aws-verify
          ;;
        *)
          echo "Unknown AWS_AUTH_METHOD '$AWS_AUTH_METHOD'. Run 'setup' to reconfigure." >&2
          exit 1
          ;;
      esac
    '';

    aws-verify.exec = ''
      aws sts get-caller-identity --profile "$AWS_PROFILE"
    '';

    # ── Terraform / OpenTofu ────────────────────────────────────────────────

    tf-bootstrap.exec = builtins.readFile ./scripts/tf-bootstrap.sh;
    tf-init.exec = builtins.readFile ./scripts/tf-init.sh;
    tf-plan.exec = ''cd "$PROJECT_ROOT/infra/terraform" && tofu plan'';
    tf-apply.exec = ''cd "$PROJECT_ROOT/infra/terraform" && tofu apply'';
    tf-destroy.exec = ''cd "$PROJECT_ROOT/infra/terraform" && tofu destroy'';

    # ── Nix binary cache sync ───────────────────────────────────────────────

    nix-cache-push.exec = builtins.readFile ./scripts/nix-cache-push.sh;
    nix-cache-pull.exec = builtins.readFile ./scripts/nix-cache-pull.sh;
    nix-cache-configure-local.exec = builtins.readFile ./scripts/nix-cache-configure-local.sh;

    # ── Container ───────────────────────────────────────────────────────────

    container-build.exec = builtins.readFile ./scripts/container-build.sh;

    # ── MLflow ──────────────────────────────────────────────────────────────

    mlflow-start.exec = ''
      echo "Starting local MLflow server at $MLFLOW_TRACKING_URI"
      mlflow server \
        --host 127.0.0.1 \
        --port 5000 \
        --default-artifact-root "$PROJECT_ROOT/mlruns" \
        --backend-store-uri "sqlite:///$PROJECT_ROOT/mlflow.db"
    '';

    mlflow-open.exec = ''
      case "''${INFRA_MODE:-local}" in
        cloud)
          EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
          echo "Tunnelling MLflow from $EC2_IP:5000 → localhost:5000 (Ctrl-C to stop)"
          ssh -N -L 5000:localhost:5000 "ml@$EC2_IP"
          ;;
        *)
          echo "Local mode — open http://localhost:5000 (start with: mlflow-start)"
          ;;
      esac
    '';

    # ── Training ────────────────────────────────────────────────────────────

    train.exec = builtins.readFile ./scripts/train.sh;
    train-status.exec = builtins.readFile ./scripts/train-status.sh;

    train-logs.exec = ''
      JOB="''${1:-}"
      if [ -z "$JOB" ]; then echo "Usage: train-logs <job-name>" >&2; exit 1; fi
      case "''${INFRA_MODE:-local}" in
        cloud)
          aws logs tail "/aws/sagemaker/TrainingJobs" \
            --log-stream-name-prefix "$JOB" --follow --region "$AWS_DEFAULT_REGION"
          ;;
        *)
          echo "train-logs is only available in cloud mode." >&2
          exit 1
          ;;
      esac
    '';

    train-on-ec2.exec = ''
      if [ "''${INFRA_MODE:-local}" != "cloud" ]; then
        echo "train-on-ec2 requires cloud mode." >&2; exit 1
      fi
      EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
      echo "SSHing into $EC2_IP and submitting training job..."
      ssh "ml@$EC2_IP" "bash -l -c 'train $*'"
    '';

    # ── Deploy / Inference ──────────────────────────────────────────────────

    deploy.exec = builtins.readFile ./scripts/deploy.sh;

    deploy-status.exec = ''
      case "''${INFRA_MODE:-local}" in
        cloud)
          PROJECT="''${TF_VAR_project:-ml-solo}"
          ENV="''${TF_VAR_environment:-dev}"
          ENDPOINT="$PROJECT-$ENV-endpoint"
          aws sagemaker describe-endpoint \
            --endpoint-name "$ENDPOINT" \
            --region "$AWS_DEFAULT_REGION" \
            --query '{Name:EndpointName,Status:EndpointStatus,Updated:LastModifiedTime}' \
            --output table
          ;;
        local)
          if curl -sf http://localhost:5001/ping > /dev/null 2>&1; then
            echo "Local inference server is running at http://localhost:5001"
          else
            echo "No local inference server running. Start with: deploy <run-id>"
          fi
          ;;
      esac
    '';

  };
}
