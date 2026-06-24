#!/usr/bin/env bash
set -euo pipefail

CONFIGS="$DEVENV_ROOT/.devenv-configs"
LOCAL_ENV="$CONFIGS/local.env"
mkdir -p "$CONFIGS/.aws"

# Re-apply devenv env.
if [ -f "$DEVENV_ROOT/.devenv/load" ]; then
  set -a; source "$DEVENV_ROOT/.devenv/load"; set +a
fi

# Load previously saved local overrides.
[ -f "$LOCAL_ENV" ] && { set -a; source "$LOCAL_ENV"; set +a; }

alias terraform=tofu

# ── Helpers ───────────────────────────────────────────────────────────────────

_save() {
  local var="$1" value="$2"
  export "${var}=${value}"
  if grep -q "^export ${var}=" "$LOCAL_ENV" 2>/dev/null; then
    sed -i.bak "s|^export ${var}=.*|export ${var}=\"${value}\"|" "$LOCAL_ENV" && rm -f "$LOCAL_ENV.bak"
  else
    echo "export ${var}=\"${value}\"" >> "$LOCAL_ENV"
  fi
}

_prompt() {
  local var="$1" prompt="$2" default="$3"
  local current="${!var:-}"
  if [ -n "$current" ] && [ "$current" != "$default" ]; then
    return  # already set to a non-default value — skip
  fi
  printf "  %s" "$prompt"
  [ -n "$default" ] && printf " [%s]" "$default"
  printf ": "
  local input
  read -r input
  local value="${input:-$default}"
  [ -n "$value" ] && _save "$var" "$value"
}

_write_iam_profile() {
  local profile="$1" key_id="$2" secret="$3" region="$4"
  local cfg="$CONFIGS/.aws/config"
  local creds="$CONFIGS/.aws/credentials"

  # Append profile to config if not already present
  if ! grep -q "\[profile ${profile}\]" "$cfg" 2>/dev/null; then
    cat >> "$cfg" <<EOF

[profile ${profile}]
region = ${region}
output = json
EOF
  fi

  # Write credentials
  if ! grep -q "\[${profile}\]" "$creds" 2>/dev/null; then
    cat >> "$creds" <<EOF

[${profile}]
aws_access_key_id = ${key_id}
aws_secret_access_key = ${secret}
EOF
  fi
}

_write_sso_profile() {
  local profile="$1" sso_url="$2" sso_region="$3" account_id="$4" role="$5" region="$6"
  local cfg="$CONFIGS/.aws/config"

  if ! grep -q "\[profile ${profile}\]" "$cfg" 2>/dev/null; then
    cat >> "$cfg" <<EOF

[profile ${profile}]
sso_start_url = ${sso_url}
sso_region = ${sso_region}
sso_account_id = ${account_id}
sso_role_name = ${role}
region = ${region}
output = json
EOF
  fi
}

# ── First-run setup wizard ────────────────────────────────────────────────────

_needs_setup() {
  [ -z "${AWS_AUTH_METHOD:-}" ] && return 0
  [ "${INFRA_MODE:-local}" = "cloud" ] && [ -z "${TF_VAR_ssh_public_key:-}" ] && return 0
  return 1
}

if _needs_setup && [[ "$-" == *i* ]]; then
  echo ""
  echo "  ┌─ First-time setup ──────────────────────────────────────────────┐"
  echo "  │  Press Enter to accept defaults shown in [brackets].            │"
  echo "  │  Run 'setup' anytime to reconfigure.                            │"
  echo "  └─────────────────────────────────────────────────────────────────┘"
  echo ""

  _prompt "TF_VAR_project"    "Project name"  "nix-ml-solo"
  _prompt "TF_VAR_aws_region" "AWS region"    "us-east-1"
  _prompt "AWS_PROFILE"       "AWS profile name" "ml-solo"

  echo ""
  echo "  Infrastructure mode:"
  echo "    1) local  — MLflow + DVC only, train/deploy run on your machine"
  echo "    2) cloud  — full AWS stack, SageMaker training, EC2 MLflow, endpoint deploy"
  echo ""
  printf "  Choice [1]: "
  read -r mode_choice
  case "${mode_choice:-1}" in
    2)
      _save "INFRA_MODE"          "cloud"
      _save "TF_VAR_infra_mode"   "cloud"

      # Auto-generate a project-specific SSH keypair if one doesn't exist yet.
      ssh_key_file="$HOME/.ssh/${TF_VAR_project:-nix-ml-solo}"
      if [ ! -f "$ssh_key_file" ]; then
        echo ""
        echo "  Generating SSH keypair: $ssh_key_file"
        ssh-keygen -t ed25519 -f "$ssh_key_file" -N "" -C "${TF_VAR_project:-nix-ml-solo}" > /dev/null
        echo "  Done. Private key saved to $ssh_key_file"
      else
        echo ""
        echo "  SSH key already exists: $ssh_key_file"
      fi
      _save "TF_VAR_ssh_public_key" "$(cat "${ssh_key_file}.pub")"
      _save "SSH_IDENTITY_FILE" "$ssh_key_file"

      _prompt "TF_VAR_ec2_instance_type" "EC2 instance type" "t3.medium"
      ;;
    *)
      _save "INFRA_MODE"          "local"
      _save "TF_VAR_infra_mode"   "local"
      ;;
  esac

  # Sync mirrored vars
  _save "TF_VAR_aws_region"  "${TF_VAR_aws_region:-us-east-1}"
  _save "TF_VAR_aws_profile" "${AWS_PROFILE:-ml-solo}"
  _save "AWS_DEFAULT_REGION" "${TF_VAR_aws_region:-us-east-1}"

  # ── Auth method ────────────────────────────────────────────────────────────
  echo ""
  echo "  AWS authentication method:"
  echo "    1) IAM user access keys  — simple, good for solo use"
  echo "    2) IAM Identity Center   — SSO, better for teams"
  echo ""
  printf "  Choice [1]: "
  read -r auth_choice
  auth_choice="${auth_choice:-1}"

  case "$auth_choice" in
    2)
      _save "AWS_AUTH_METHOD" "sso"
      echo ""
      printf "  SSO start URL (e.g. https://my-org.awsapps.com/start): "
      read -r sso_url
      printf "  SSO region [${TF_VAR_aws_region:-us-east-1}]: "
      read -r sso_region; sso_region="${sso_region:-${TF_VAR_aws_region:-us-east-1}}"
      printf "  AWS account ID: "
      read -r account_id
      printf "  SSO role name [AdministratorAccess]: "
      read -r sso_role; sso_role="${sso_role:-AdministratorAccess}"

      _save "AWS_SSO_START_URL" "$sso_url"
      _save "AWS_SSO_REGION"    "$sso_region"
      _write_sso_profile "${AWS_PROFILE:-ml-solo}" "$sso_url" "$sso_region" "$account_id" "$sso_role" "${TF_VAR_aws_region:-us-east-1}"

      echo ""
      printf "  Run aws-login now to authenticate? [Y/n]: "
      read -r ans
      case "${ans:-y}" in [Yy]*) aws-login ;; esac
      ;;
    *)
      _save "AWS_AUTH_METHOD" "iam"
      profile="${AWS_PROFILE:-ml-solo}"
      region="${TF_VAR_aws_region:-us-east-1}"
      project="${TF_VAR_project:-nix-ml-solo}"
      iam_user="${project}-deploy"

      echo ""
      echo "  We'll create a dedicated IAM user '${iam_user}' with permanent access keys."
      echo "  You need temporary admin credentials once to bootstrap this (used once, never saved)."
      echo ""
      echo "  ── How to get credentials from the AWS Console ──────────────────"
      echo ""
      echo "  New AWS account (root user):"
      echo "    1. Sign in at https://console.aws.amazon.com"
      echo "    2. Click your account name (top-right) → Security credentials"
      echo "    3. Scroll to \"Access keys\" → Create access key → Command Line Interface"
      echo "    4. Copy the Access Key ID and Secret Access Key shown on screen"
      echo ""
      echo "  Existing IAM admin user:"
      echo "    1. IAM → Users → your username → Security credentials tab"
      echo "    2. Create access key → Command Line Interface → copy both values"
      echo ""
      echo "  ─────────────────────────────────────────────────────────────────"
      echo ""
      printf "  Bootstrap AWS Access Key ID: "
      read -r boot_key_id
      printf "  Bootstrap AWS Secret Access Key: "
      read -rs boot_secret; echo ""

      export AWS_ACCESS_KEY_ID="$boot_key_id"
      export AWS_SECRET_ACCESS_KEY="$boot_secret"
      export AWS_DEFAULT_REGION="$region"

      echo ""
      echo "  Verifying bootstrap credentials..."
      if ! aws sts get-caller-identity --output text --query 'Account' > /dev/null 2>&1; then
        echo "  Error: could not authenticate with provided credentials." >&2
        echo "  Falling back to manual key entry." >&2
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        echo ""
        printf "  AWS Access Key ID: "
        read -r key_id
        printf "  AWS Secret Access Key: "
        read -rs secret; echo ""
        _write_iam_profile "$profile" "$key_id" "$secret" "$region"
      else
        account_id=$(aws sts get-caller-identity --query 'Account' --output text)
        echo "  Authenticated as account ${account_id}."

        # Create IAM user if it doesn't exist
        if aws iam get-user --user-name "$iam_user" > /dev/null 2>&1; then
          echo "  IAM user '${iam_user}' already exists, skipping creation."
        else
          echo "  Creating IAM user '${iam_user}'..."
          aws iam create-user --user-name "$iam_user" > /dev/null
        fi

        # Attach policy
        policy_arn="arn:aws:iam::aws:policy/AdministratorAccess"
        printf "  Use AdministratorAccess policy? Recommended for initial setup. [Y/n]: "
        read -r use_admin
        if [[ "${use_admin:-y}" =~ ^[Nn] ]]; then
          echo "  Creating scoped IAM policy for '${iam_user}'..."
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

        echo "  Attaching policy..."
        aws iam attach-user-policy --user-name "$iam_user" --policy-arn "$policy_arn" > /dev/null

        # Generate access keys
        echo "  Generating access keys..."
        keys=$(aws iam create-access-key --user-name "$iam_user" --output json)
        new_key_id=$(echo "$keys" | jq -r '.AccessKey.AccessKeyId')
        new_secret=$(echo "$keys"  | jq -r '.AccessKey.SecretAccessKey')

        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

        _write_iam_profile "$profile" "$new_key_id" "$new_secret" "$region"
        _save "IAM_USER" "$iam_user"

        echo "  IAM user '${iam_user}' ready."
      fi

      echo ""
      printf "  Verify credentials now? [Y/n]: "
      read -r ans
      case "${ans:-y}" in [Yy]*) aws-verify ;; esac
      ;;
  esac

  echo ""
  echo "  Saved to .devenv-configs/local.env"

  # ── Deploy infra (cloud mode only) ────────────────────────────────────────
  if [ "${INFRA_MODE:-local}" = "cloud" ]; then
  echo ""
  echo "  ┌─ Deploy infrastructure ─────────────────────────────────────────┐"
  echo "  │  This will run: tf-bootstrap → tf-init → tf-plan → tf-apply     │"
  echo "  │  Creates: EC2 (NixOS), S3 buckets, ECR, SageMaker config        │"
  echo "  │  Estimated cost: ~\$36/month (EC2 + storage)                     │"
  echo "  └─────────────────────────────────────────────────────────────────┘"
  echo ""
  printf "  Deploy now? [y/N]: "
  read -r deploy_ans
  if [[ "${deploy_ans:-n}" =~ ^[Yy] ]]; then
    echo ""
    echo "  Running tf-bootstrap..."
    tf-bootstrap

    echo ""
    echo "  Running tf-init..."
    tf-init

    echo ""
    echo "  Running tf-plan (review before applying)..."
    tf-plan

    echo ""
    printf "  Apply the plan? [y/N]: "
    read -r apply_ans
    if [[ "${apply_ans:-n}" =~ ^[Yy] ]]; then
      tf-apply
      echo ""
      echo "  Infrastructure deployed. Run 'mlflow-open' to open the MLflow UI."
    else
      echo "  Skipped. Run 'tf-apply' when ready."
    fi
  else
    echo "  Skipped. Run 'tf-bootstrap && tf-init && tf-plan && tf-apply' when ready."
  fi
  fi  # end cloud mode block

  echo ""
fi
