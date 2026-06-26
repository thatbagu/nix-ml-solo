#!/usr/bin/env bash
# Setup wizard — sourced by enter-shell.sh after _lib.sh.

_needs_setup() {
  [ -z "${AWS_AUTH_METHOD:-}" ] && return 0
  [ "${INFRA_MODE:-local}" = "cloud" ] && [ -z "${TF_VAR_ssh_public_key:-}" ] && return 0
  return 1
}

_run_wizard() {
  set -euo pipefail

  gum style \
    --border rounded --border-foreground 212 \
    --padding "0 2" --margin "1 0" \
    "$(gum style --bold 'First-time setup')" \
    "Use arrow keys / type to filter. Enter accepts. Ctrl-C aborts." \
    "Run 'setup' anytime to reconfigure."

  # ── Basic config ─────────────────────────────────────────────────────────────
  # Project name and environment come from devenv.nix — not asked here.

  _gum_region \
    "TF_VAR_aws_region" \
    "AWS region" \
    "us-east-1"

  _gum_input_default \
    "AWS_PROFILE" \
    "AWS profile name" \
    "ml-solo" \
    _valid_profile_name \
    "Must start with a letter, 2-64 alphanumeric/hyphen/underscore chars"

  # ── Infrastructure mode ───────────────────────────────────────────────────────

  if ! _already_set "INFRA_MODE" "local"; then
    local mode_label
    mode_label=$(gum choose \
      --header "Infrastructure mode:" \
      "local  — MLflow + DVC only, train/deploy on your machine" \
      "cloud  — full AWS stack: SageMaker, EC2 MLflow, endpoint")
    local mode="${mode_label%%  *}"
    _save "INFRA_MODE"        "$mode"
    _save "TF_VAR_infra_mode" "$mode"
  fi

  if [ "${INFRA_MODE:-local}" = "cloud" ]; then
    local ssh_key_file="$HOME/.ssh/${TF_VAR_project:-nix-ml-solo}"
    if [ ! -f "$ssh_key_file" ]; then
      gum log --level info "Generating SSH keypair: $ssh_key_file"
      ssh-keygen -t ed25519 -f "$ssh_key_file" -N "" -C "${TF_VAR_project:-nix-ml-solo}" > /dev/null
      gum log --level info "Done. Private key: $ssh_key_file"
    else
      gum log --level info "SSH key already exists: $ssh_key_file"
    fi
    _save "TF_VAR_ssh_public_key" "$(cat "${ssh_key_file}.pub")"
    _save "SSH_IDENTITY_FILE" "$ssh_key_file"

    if ! _already_set "TF_VAR_ec2_instance_type" "t3.medium"; then
      local ec2_type
      ec2_type=$(gum choose \
        --header "EC2 instance type for MLflow server:" \
        "t3.micro  (free-tier eligible, sufficient for MLflow)" \
        "t3.small" "t3.medium" "t3.large" \
        "m5.large" "m5.xlarge" "m5.2xlarge" \
        "c5.large" "c5.xlarge" \
        "g4dn.xlarge" "g4dn.2xlarge" \
        "other (enter below)")
      ec2_type="${ec2_type%% *}"
      if [ "$ec2_type" = "other" ]; then
        _gum_input_default \
          "TF_VAR_ec2_instance_type" \
          "EC2 instance type (e.g. r5.xlarge, p3.2xlarge)" \
          "t3.medium" \
          _valid_ec2_type \
          "Invalid format — expected e.g. t3.medium, m5.xlarge, g4dn.2xlarge"
      else
        _save "TF_VAR_ec2_instance_type" "$ec2_type"
      fi
    fi
  fi

  _save "TF_VAR_aws_region"  "${TF_VAR_aws_region:-us-east-1}"
  _save "TF_VAR_aws_profile" "${AWS_PROFILE:-ml-solo}"
  _save "AWS_DEFAULT_REGION" "${TF_VAR_aws_region:-us-east-1}"

  # ── Auth method ───────────────────────────────────────────────────────────────

  local auth_label
  auth_label=$(gum choose \
    --header "AWS authentication method:" \
    "IAM user keys   — simple, good for solo use" \
    "Identity Center — SSO, better for teams")

  case "$auth_label" in
    "Identity Center"*)
      _gum_input \
        "AWS_SSO_START_URL" \
        "SSO start URL" \
        "https://my-org.awsapps.com/start" \
        _valid_https_url \
        "Must be a valid https:// URL"

      _gum_region \
        "AWS_SSO_REGION" \
        "SSO region (usually same as your AWS region)" \
        "${TF_VAR_aws_region:-us-east-1}"

      local account_id
      account_id=$(gum input \
        --header "AWS account ID (12 digits)" \
        --placeholder "123456789012")
      while ! _valid_account_id "$account_id"; do
        gum log --level error "Must be exactly 12 digits."
        account_id=$(gum input --header "AWS account ID" --placeholder "123456789012")
      done

      local sso_role
      sso_role=$(gum input \
        --header "SSO role name" \
        --placeholder "AdministratorAccess" \
        --value "AdministratorAccess")
      sso_role="${sso_role:-AdministratorAccess}"

      _write_sso_profile \
        "${AWS_PROFILE:-ml-solo}" \
        "${AWS_SSO_START_URL}" \
        "${AWS_SSO_REGION}" \
        "$account_id" "$sso_role" \
        "${TF_VAR_aws_region:-us-east-1}"

      _save "AWS_AUTH_METHOD" "sso"

      if gum confirm "Run aws-login now to open the browser auth flow?"; then
        aws-login
      fi
      ;;

    *)
      local profile="${AWS_PROFILE:-ml-solo}"
      local region="${TF_VAR_aws_region:-us-east-1}"
      local project="${TF_VAR_project:-nix-ml-solo}"
      local iam_user="${project}-deploy"

      gum style \
        --border normal --border-foreground 240 \
        --padding "0 1" --margin "1 0" \
        "We'll create IAM user '${iam_user}' with permanent access keys." \
        "Temporary admin credentials are needed once — never saved to disk." \
        "" \
        "$(gum style --bold 'Root account (brand-new AWS account):')" \
        "  console.aws.amazon.com → your name (top-right) → Security credentials" \
        "  → Access keys → Create access key → CLI → copy both values" \
        "" \
        "$(gum style --bold 'Existing IAM admin user:')" \
        "  IAM → Users → your name → Security credentials tab → Create access key"

      local boot_key_id
      while true; do
        boot_key_id=$(gum input \
          --header "Bootstrap AWS Access Key ID  (starts with AKIA or ASIA, 20 chars)" \
          --placeholder "AKIAIOSFODNN7EXAMPLE")
        _valid_aws_key_id "$boot_key_id" && break
        gum log --level error "Invalid. Must start with AKIA or ASIA and be exactly 20 uppercase alphanumeric chars."
      done

      local boot_secret
      boot_secret=$(gum input --password \
        --header "Bootstrap AWS Secret Access Key")

      export AWS_ACCESS_KEY_ID="$boot_key_id"
      export AWS_SECRET_ACCESS_KEY="$boot_secret"
      export AWS_DEFAULT_REGION="$region"
      local saved_profile="${AWS_PROFILE:-}"
      unset AWS_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE

      gum log --level info "Verifying bootstrap credentials…"
      local verify_output verify_exit
      verify_output=$(aws sts get-caller-identity --output text --query 'Account' 2>&1) \
        && verify_exit=0 || verify_exit=$?

      [ -n "$saved_profile" ] && export AWS_PROFILE="$saved_profile"
      export AWS_CONFIG_FILE="$CONFIGS/.aws/config"
      export AWS_SHARED_CREDENTIALS_FILE="$CONFIGS/.aws/credentials"

      if [ "$verify_exit" -ne 0 ]; then
        gum log --level error "Could not authenticate: $verify_output"
        gum log --level error "Check the credentials and run 'setup' to retry."
        set +euo pipefail; return 1
      fi

      unset AWS_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE

      local account_id
      account_id=$(echo "$verify_output")
      gum log --level info "Authenticated as account ${account_id}."

      if aws iam get-user --user-name "$iam_user" > /dev/null 2>&1; then
        gum log --level info "IAM user '${iam_user}' already exists, skipping creation."
      else
        gum spin --spinner dot --title "Creating IAM user '${iam_user}'…" -- \
          aws iam create-user --user-name "$iam_user" > /dev/null
      fi

      local policy_arn="arn:aws:iam::aws:policy/AdministratorAccess"
      if ! gum confirm "Attach AdministratorAccess? (recommended for initial setup)"; then
        gum log --level info "Creating scoped IAM policy for '${iam_user}'…"
        local policy_doc
        policy_doc=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:*","s3:*","dynamodb:*","iam:*",
      "sagemaker:*","ecr:*","logs:*","sts:GetCallerIdentity"
    ],
    "Resource": "*"
  }]
}
POLICY
)
        policy_arn=$(aws iam create-policy \
          --policy-name "${project}-deploy-policy" \
          --policy-document "$policy_doc" \
          --query 'Policy.Arn' --output text 2>/dev/null || \
          echo "arn:aws:iam::${account_id}:policy/${project}-deploy-policy")
      fi

      gum spin --spinner dot --title "Attaching policy…" -- \
        aws iam attach-user-policy --user-name "$iam_user" --policy-arn "$policy_arn" > /dev/null

      local need_new_key=true
      if aws sts get-caller-identity \
           --profile "$profile" \
           --no-cli-pager > /dev/null 2>&1; then
        gum log --level info "Existing credentials in .devenv-configs still work — skipping key generation."
        need_new_key=false
      fi

      if [ "$need_new_key" = true ]; then
        local key_count
        key_count=$(aws iam list-access-keys --user-name "$iam_user" \
          --query 'length(AccessKeyMetadata)' --output text)
        if [ "${key_count:-0}" -ge 2 ]; then
          local oldest_key
          oldest_key=$(aws iam list-access-keys --user-name "$iam_user" \
            --query 'sort_by(AccessKeyMetadata, &CreateDate)[0].AccessKeyId' \
            --output text)
          gum log --level warn "IAM key quota full (2/2). Deleting oldest key: $oldest_key"
          aws iam delete-access-key --user-name "$iam_user" --access-key-id "$oldest_key" > /dev/null
        fi

        gum log --level info "Generating permanent access keys…"
        local keys new_key_id new_secret
        keys=$(aws iam create-access-key --user-name "$iam_user" --output json)
        new_key_id=$(echo "$keys" | jq -r '.AccessKey.AccessKeyId')
        new_secret=$(echo "$keys"  | jq -r '.AccessKey.SecretAccessKey')

        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

        local creds="$CONFIGS/.aws/credentials"
        if grep -q "\[${profile}\]" "$creds" 2>/dev/null; then
          sed -i.bak "/^\[${profile}\]/,/^\[/{
            s|aws_access_key_id = .*|aws_access_key_id = ${new_key_id}|
            s|aws_secret_access_key = .*|aws_secret_access_key = ${new_secret}|
          }" "$creds" && rm -f "$creds.bak"
        else
          _write_iam_profile "$profile" "$new_key_id" "$new_secret" "$region"
        fi

        export AWS_PROFILE="$profile"
        export AWS_CONFIG_FILE="$CONFIGS/.aws/config"
        export AWS_SHARED_CREDENTIALS_FILE="$CONFIGS/.aws/credentials"

        gum log --level info "Waiting for new credentials to propagate (~10s)…"
        local try=1 max_tries=9
        while [ $try -le $max_tries ]; do
          sleep 5
          if aws sts get-caller-identity --profile "$profile" > /dev/null 2>&1; then
            gum log --level info "Credentials verified and active."
            break
          fi
          if [ $try -eq $max_tries ]; then
            gum log --level warn "Not active after $((max_tries * 5))s — will propagate shortly. Run 'aws-verify' to confirm."
          else
            gum log --level info "Not ready yet (${try}/${max_tries})…"
          fi
          try=$((try + 1))
        done
      else
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        export AWS_PROFILE="$profile"
        export AWS_CONFIG_FILE="$CONFIGS/.aws/config"
        export AWS_SHARED_CREDENTIALS_FILE="$CONFIGS/.aws/credentials"
      fi

      _save "IAM_USER" "$iam_user"
      _save "AWS_AUTH_METHOD" "iam"

      gum log --level info "IAM user '${iam_user}' ready."
      ;;
  esac

  gum log --level info "Saved to .devenv-configs/local.env"

  # ── Deploy infra (cloud mode only) ──────────────────────────────────────────
  if [ "${INFRA_MODE:-local}" = "cloud" ]; then
    gum style \
      --border rounded --border-foreground 212 \
      --padding "0 2" --margin "1 0" \
      "$(gum style --bold 'Deploy infrastructure')" \
      "tf-bootstrap → tf-init → tf-plan → tf-apply" \
      "Creates: EC2 (NixOS), S3, ECR, SageMaker config" \
      "Estimated cost: ~\$36/month (EC2 + storage)"

    if gum confirm "Deploy now?"; then
      echo ""
      tf-bootstrap
      echo ""
      tf-init
      echo ""
      tf-plan
      if gum confirm "Apply the plan?"; then
        tf-apply

        if [ -d "$PROJECT_ROOT/backups" ] && [ -n "$(ls -A "$PROJECT_ROOT/backups" 2>/dev/null)" ]; then
          echo ""
          gum log --level info "Previous backup found in backups/."
          if gum confirm "Restore MLflow experiments and DVC data from a previous teardown?"; then
            restore
          fi
        fi

        echo ""
        gum log --level info "Pushing Nix packages to S3 cache (EC2 will pull these on first boot)…"
        nix-sync

        echo ""
        gum log --level info "Building and pushing minimal container image to ECR…"
        container-build

        echo ""
        gum log --level info "Waiting for EC2 to be ready, then opening MLflow and Jupyter…"
        gum log --level info "(NixOS first boot can take 5-15 min — this will retry automatically)"

        mlflow-open

        echo ""
        gum log --level info "Starting file sync (mutagen bidirectional)…"
        sync-ec2

        echo ""
        gum log --level info "Starting JupyterLab on EC2…"
        jupyter-ec2

        echo ""
        gum style \
          --border rounded --border-foreground 212 \
          --padding "0 2" --margin "1 0" \
          "$(gum style --bold 'Setup complete')" \
          "  MLflow    → http://localhost:${MLFLOW_PORT:-5000}" \
          "  Jupyter   → http://localhost:${JUPYTER_PORT:-8888}" \
          "  File sync → mutagen (bidirectional, real-time)" \
          "" \
          "  train <script>   — run training" \
          "  deploy <run-id>  — deploy to SageMaker"
      else
        gum log --level warn "Skipped tf-apply. Run it when ready."
      fi
    else
      gum log --level warn "Skipped. Run 'tf-bootstrap && tf-init && tf-plan && tf-apply' when ready."
    fi
  fi

  set +euo pipefail
}
