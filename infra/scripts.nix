_:
{
  scripts = {

    # ── Setup ───────────────────────────────────────────────────────────────

    setup.exec = ''
      rm -f "$DEVENV_ROOT/.devenv-configs/local.env"
      unset AWS_AUTH_METHOD INFRA_MODE TF_VAR_infra_mode TF_VAR_ssh_public_key SSH_IDENTITY_FILE
      # Source helpers into this subprocess, then call the wizard directly
      # (bypasses the [[ "$-" == *i* ]] guard that protects the enterShell path).
      source "$DEVENV_ROOT/infra/scripts/enter-shell.sh"
      _run_wizard
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
    # Push the devenv closure to the S3 nix cache so EC2 can pull it without rebuilding.
    nix-sync.exec = builtins.readFile ./scripts/nix-sync.sh;

    # ── MLflow ──────────────────────────────────────────────────────────────

    mlflow-start.exec = ''
      echo "Starting local MLflow server at $MLFLOW_TRACKING_URI"
      uv run mlflow server \
        --host 127.0.0.1 \
        --port 5000 \
        --default-artifact-root "$PROJECT_ROOT/mlruns" \
        --backend-store-uri "sqlite:///$PROJECT_ROOT/mlflow.db"
    '';

    mlflow-open.exec = ''
      case "''${INFRA_MODE:-local}" in
        cloud)
          EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
          pkill -f "ssh.*5000:localhost:5000" 2>/dev/null || true
          echo "Connecting to $EC2_IP — will retry until NixOS first-boot completes (5-15 min)…"
          until ssh \
              -f \
              -o StrictHostKeyChecking=accept-new \
              -o ConnectTimeout=10 \
              -o BatchMode=yes \
              -i "$SSH_IDENTITY_FILE" \
              -N -L 5000:localhost:5000 \
              "ml@$EC2_IP" 2>/dev/null; do
            printf "  Not ready yet — retrying in 20s…\r"
            sleep 20
          done
          echo "Tunnel active → http://localhost:5000  (mlflow-close to stop)"
          ;;
        *)
          echo "Local mode — open http://localhost:5000 (start with: mlflow-start)"
          ;;
      esac
    '';

    mlflow-close.exec = ''
      pkill -f "ssh.*5000:localhost:5000" && echo "MLflow tunnel closed." || echo "No tunnel running."
    '';

    # ── Unified sync ────────────────────────────────────────────────────────

    sync.exec = ''
      if [ "''${INFRA_MODE:-local}" != "cloud" ]; then
        echo "sync requires cloud mode." >&2; exit 1
      fi

      STAMPS="$DEVENV_ROOT/.devenv-configs"

      # 1. Mutagen — bidirectional file sync
      if ! mutagen sync list nix-ml-solo 2>/dev/null | grep -q "Watching"; then
        echo "[ sync ] starting file sync session…"
        sync-ec2
      else
        echo "[ sync ] file sync running"
      fi

      # 2. Nix cache — push devenv closure to S3 if profile changed
      _CUR=$(readlink -f "$DEVENV_ROOT/.devenv/profile" 2>/dev/null || true)
      _PREV=$(cat "$STAMPS/.last-synced-profile" 2>/dev/null || true)
      if [ -n "$_CUR" ] && [ "$_CUR" != "$_PREV" ]; then
        echo "[ sync ] devenv profile changed — pushing Nix closure to S3…"
        nix-sync && echo "$_CUR" > "$STAMPS/.last-synced-profile"
      else
        echo "[ sync ] Nix cache up to date"
      fi

      # 3. NixOS rebuild — push devenv.nix + devenv.lock to EC2 if changed
      _HASH=$(md5sum "$DEVENV_ROOT/devenv.nix" "$DEVENV_ROOT/devenv.lock" 2>/dev/null | md5sum | cut -d" " -f1)
      _PREV_HASH=$(cat "$STAMPS/.last-nixos-rebuilt" 2>/dev/null || true)
      if [ "$_HASH" != "$_PREV_HASH" ]; then
        echo "[ sync ] devenv.nix or devenv.lock changed — rebuilding EC2…"
        nixos-rebuild && echo "$_HASH" > "$STAMPS/.last-nixos-rebuilt"
      else
        echo "[ sync ] EC2 NixOS config up to date"
      fi
    '';

    # ── EC2 sync (mutagen — bidirectional, real-time) ────────────────────────

    sync-ec2.exec = ''
      if [ "''${INFRA_MODE:-local}" != "cloud" ]; then
        echo "sync-ec2 requires cloud mode." >&2; exit 1
      fi
      EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)

      # Write SSH config entry so mutagen can reach EC2 with the right key.
      # The IP is dynamic (changes on EC2 restart), so we regenerate each time.
      mkdir -p "$HOME/.ssh/config.d"
      cat > "$HOME/.ssh/config.d/nix-ml-solo" << EOF
Host nix-ml-solo-ec2
  HostName $EC2_IP
  User ml
  IdentityFile ''${SSH_IDENTITY_FILE:-$HOME/.ssh/nix-ml-solo}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
      # Ensure ~/.ssh/config includes config.d (idempotent)
      if ! grep -q "Include config.d/\*" "$HOME/.ssh/config" 2>/dev/null; then
        printf "Include config.d/*\n\n" | cat - "$HOME/.ssh/config" 2>/dev/null > /tmp/_sshcfg && mv /tmp/_sshcfg "$HOME/.ssh/config" || \
          echo "Include config.d/*" > "$HOME/.ssh/config"
      fi

      # Terminate any existing session and recreate (handles IP changes after restart)
      mutagen sync terminate nix-ml-solo 2>/dev/null || true
      mutagen sync create \
        --name nix-ml-solo \
        --mode two-way-resolved \
        --ignore-vcs \
        --ignore '.devenv' --ignore '.direnv' --ignore '.devenv-configs' \
        --ignore '.venv' --ignore 'mlruns' --ignore '__pycache__' \
        --ignore '*.pyc' --ignore '*.db' \
        "$PROJECT_ROOT" \
        "nix-ml-solo-ec2:/home/ml/project"
      echo "Sync session started — bidirectional, real-time."
      echo "Run 'sync-ec2-status' to check, 'sync-ec2-stop' to terminate."
    '';

    sync-ec2-status.exec = ''
      mutagen sync list nix-ml-solo 2>/dev/null || echo "No active sync session."
    '';

    sync-ec2-stop.exec = ''
      mutagen sync terminate nix-ml-solo 2>/dev/null && echo "Sync session terminated." || echo "No session to stop."
    '';

    # ── Jupyter on EC2 ──────────────────────────────────────────────────────

    jupyter-ec2.exec = ''
      if [ "''${INFRA_MODE:-local}" != "cloud" ]; then
        echo "jupyter-ec2 requires cloud mode." >&2; exit 1
      fi
      EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
      SSH="ssh -i $SSH_IDENTITY_FILE -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

      # Start JupyterLab on EC2 if it's not already running.
      # Run inside devenv shell so all env vars from devenv.nix are inherited
      # (MLFLOW_TRACKING_URI, venv PATH, etc.) without hardcoding anything here.
      until $SSH "ml@$EC2_IP" "
        if ! pgrep -x jupyter-lab > /dev/null 2>&1; then
          mkdir -p /home/ml/project
          cd /home/ml/project
          nohup /run/current-system/sw/bin/devenv shell -- \
            jupyter lab \
            --no-browser \
            --port 8888 \
            --ip 127.0.0.1 \
            --ServerApp.token=\"\" \
            --ServerApp.password=\"\" \
            > /home/ml/jupyter.log 2>&1 &
          disown
          sleep 3
          echo 'JupyterLab started'
        else
          echo 'JupyterLab already running'
        fi
      " 2>/dev/null; do
        printf "  EC2 not ready yet — retrying in 20s…\r"
        sleep 20
      done

      # Kill any stale tunnel
      pkill -f "ssh.*8888:localhost:8888" 2>/dev/null || true

      echo "Opening SSH tunnel → http://localhost:8888"
      ssh \
        -f \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -i "$SSH_IDENTITY_FILE" \
        -N -L 8888:localhost:8888 \
        "ml@$EC2_IP"
      echo "Tunnel active → http://localhost:8888  (jupyter-ec2-close to stop)"
    '';

    jupyter-ec2-close.exec = ''
      pkill -f "ssh.*8888:localhost:8888" && echo "Jupyter tunnel closed." || echo "No tunnel running."
      EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip 2>/dev/null) || true
      if [ -n "''${EC2_IP:-}" ]; then
        ssh -i "$SSH_IDENTITY_FILE" -o IdentitiesOnly=yes -o IdentityAgent=none \
          "ml@$EC2_IP" "pkill -x jupyter-lab || true" 2>/dev/null || true
      fi
    '';

    # ── NixOS remote rebuild ─────────────────────────────────────────────────

    nixos-rebuild.exec = ''
      if [ "''${INFRA_MODE:-local}" != "cloud" ]; then
        echo "nixos-rebuild requires cloud mode." >&2; exit 1
      fi
      CONFIG="$DEVENV_ROOT/.devenv-configs/nixos-config.nix"
      if [ ! -f "$CONFIG" ]; then
        echo "Run tf-apply first to generate .devenv-configs/nixos-config.nix" >&2; exit 1
      fi
      EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
      SSH="ssh -i $SSH_IDENTITY_FILE -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=accept-new"

      echo "Pushing NixOS config to $EC2_IP…"
      $SSH "ml@$EC2_IP" "sudo tee /etc/nixos/configuration.nix > /dev/null" < "$CONFIG"

      echo "Pushing devenv environment files…"
      $SSH "ml@$EC2_IP" "mkdir -p /home/ml/project"
      $SSH "ml@$EC2_IP" "cat > /home/ml/project/devenv.nix"  < "$DEVENV_ROOT/devenv.nix"
      $SSH "ml@$EC2_IP" "cat > /home/ml/project/devenv.lock" < "$DEVENV_ROOT/devenv.lock"
      # pyproject.toml + uv.lock are needed so devenv's uv sync succeeds on activation.
      for f in pyproject.toml uv.lock; do
        [ -f "$DEVENV_ROOT/$f" ] && $SSH "ml@$EC2_IP" "cat > /home/ml/project/$f" < "$DEVENV_ROOT/$f" || true
      done

      echo "Rebuilding NixOS (this takes a minute)…"
      $SSH "ml@$EC2_IP" "sudo nixos-rebuild switch 2>&1"

      echo "Restarting devenv-build to pick up new packages…"
      $SSH "ml@$EC2_IP" "sudo systemctl restart devenv-build.service && sudo systemctl is-active --wait devenv-build.service"

      echo "Done."
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

      SCRIPT="''${1:-''${TRAINING_SCRIPT:-}}"
      [ $# -gt 0 ] && shift
      [ "''${1:-}" = "--" ] && shift
      if [ -z "$SCRIPT" ]; then
        echo "Usage: train-on-ec2 <script.py|notebook.ipynb> [-- args...]" >&2; exit 1
      fi

      EC2_IP=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw ec2_public_ip)
      SSH="ssh -i $SSH_IDENTITY_FILE -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
      DEVENV_RUN="devenv shell --"

      echo "Files synced via mutagen — skipping rsync."

      EC2_MLFLOW="http://localhost:5000"
      EC2_DVC=$(cd "$PROJECT_ROOT/infra/terraform" && tofu output -raw dvc_bucket_url 2>/dev/null || echo "''${DVC_REMOTE_URL:-}")

      echo "▶ Training on EC2: $SCRIPT $*"
      echo "  MLflow : $EC2_MLFLOW"
      echo ""

      case "$SCRIPT" in
        *.ipynb)
          OUT="''${SCRIPT%.ipynb}-executed.ipynb"
          $SSH "ml@$EC2_IP" "
            cd ~/project
            MLFLOW_TRACKING_URI=$EC2_MLFLOW \
            DVC_REMOTE_URL=$EC2_DVC \
            $DEVENV_RUN uv run papermill '$SCRIPT' '$OUT' $*"
          ;;
        *)
          $SSH "ml@$EC2_IP" "
            cd ~/project
            MLFLOW_TRACKING_URI=$EC2_MLFLOW \
            DVC_REMOTE_URL=$EC2_DVC \
            $DEVENV_RUN uv run python '$SCRIPT' $*"
          ;;
      esac
    '';

    # ── Deploy / Inference ──────────────────────────────────────────────────

    deploy.exec = builtins.readFile ./scripts/deploy.sh;
    teardown.exec = builtins.readFile ./scripts/teardown.sh;
    restore.exec = builtins.readFile ./scripts/restore.sh;

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
