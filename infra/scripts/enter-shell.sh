#!/usr/bin/env bash
# Sourced into the interactive devenv bash session via enterShell.
# set -euo pipefail is scoped inside _run_wizard only and reset before returning.

CONFIGS="$DEVENV_ROOT/.devenv-configs"
LOCAL_ENV="$CONFIGS/local.env"
mkdir -p "$CONFIGS/.aws"

if [ -f "$DEVENV_ROOT/.devenv/load" ]; then
  set -a; source "$DEVENV_ROOT/.devenv/load"; set +a
fi

[ -f "$LOCAL_ENV" ] && { set -a; source "$LOCAL_ENV"; set +a; }

alias terraform=tofu

# ── Persistence helpers ────────────────────────────────────────────────────────

_save() {
  local var="$1" value="$2"
  export "${var}=${value}"
  if grep -q "^export ${var}=" "$LOCAL_ENV" 2>/dev/null; then
    sed -i.bak "s|^export ${var}=.*|export ${var}=\"${value}\"|" "$LOCAL_ENV" && rm -f "$LOCAL_ENV.bak"
  else
    echo "export ${var}=\"${value}\"" >> "$LOCAL_ENV"
  fi
}

# Returns 0 if var is already saved to a non-default, non-empty value.
_already_set() {
  local var="$1" default="$2"
  local current="${!var:-}"
  [ -n "$current" ] && [ "$current" != "$default" ]
}

# ── AWS profile writers ────────────────────────────────────────────────────────

_write_iam_profile() {
  local profile="$1" key_id="$2" secret="$3" region="$4"
  local cfg="$CONFIGS/.aws/config"
  local creds="$CONFIGS/.aws/credentials"
  if ! grep -q "\[profile ${profile}\]" "$cfg" 2>/dev/null; then
    cat >> "$cfg" <<EOF

[profile ${profile}]
region = ${region}
output = json
EOF
  fi
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

# ── Validators ─────────────────────────────────────────────────────────────────

# Valid AWS regions (updated 2025)
_VALID_AWS_REGIONS=(
  us-east-1 us-east-2 us-west-1 us-west-2
  af-south-1
  ap-east-1 ap-south-1 ap-south-2
  ap-southeast-1 ap-southeast-2 ap-southeast-3 ap-southeast-4 ap-southeast-5 ap-southeast-7
  ap-northeast-1 ap-northeast-2 ap-northeast-3
  ca-central-1 ca-west-1
  eu-central-1 eu-central-2
  eu-west-1 eu-west-2 eu-west-3
  eu-north-1 eu-south-1 eu-south-2
  il-central-1
  me-central-1 me-south-1
  mx-central-1
  sa-east-1
)

_valid_region() {
  local r="$1"
  for region in "${_VALID_AWS_REGIONS[@]}"; do
    [ "$r" = "$region" ] && return 0
  done
  return 1
}

# S3-compatible: 3-63 chars, lowercase alphanumeric/hyphens, start with letter
_valid_project_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{2,62}$ ]]; }

# Profile name: letter-started, alphanumeric/hyphen/underscore
_valid_profile_name() { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{1,63}$ ]]; }

# EC2: e.g. t3.medium, m5.xlarge, g4dn.2xlarge, c6i.4xlarge, r5.metal
_valid_ec2_type() { [[ "$1" =~ ^[a-z][a-z0-9]+(\.metal|(\.[0-9]*x?large|\.medium|\.small|\.micro|\.nano))$ ]]; }

# IAM access key IDs: AKIA or ASIA + 16 uppercase alphanumeric = 20 chars total
_valid_aws_key_id() { [[ "$1" =~ ^(AKIA|ASIA)[A-Z0-9]{16}$ ]]; }

# AWS account ID: exactly 12 digits
_valid_account_id() { [[ "$1" =~ ^[0-9]{12}$ ]]; }

# Basic URL: must start with https://
_valid_https_url() { [[ "$1" =~ ^https:// ]]; }

# ── gum-backed prompt helpers ──────────────────────────────────────────────────

# _gum_input VAR "Header text" "placeholder" validate_fn "error message" [--password]
# Loops until validate_fn passes, then _save VAR.
# Skips if var is already set to something other than placeholder.
_gum_input() {
  local var="$1" header="$2" placeholder="$3" validate_fn="$4" errmsg="$5"
  local pw_flag="${6:-}"
  _already_set "$var" "$placeholder" && return
  local value
  while true; do
    if [ "$pw_flag" = "--password" ]; then
      value=$(gum input --password --header "$header" --placeholder "$placeholder")
    else
      value=$(gum input --header "$header" --placeholder "$placeholder" --value "${!var:-}")
    fi
    if [ -z "$value" ]; then
      gum log --level error "Cannot be empty."
      continue
    fi
    if "$validate_fn" "$value"; then
      break
    fi
    gum log --level error "$errmsg"
  done
  _save "$var" "$value"
}

# Like _gum_input but pre-fills with default and accepts Enter to keep default.
_gum_input_default() {
  local var="$1" header="$2" default="$3" validate_fn="$4" errmsg="$5"
  _already_set "$var" "$default" && return
  local value
  while true; do
    value=$(gum input --header "$header" --placeholder "$default" --value "${!var:-$default}")
    value="${value:-$default}"
    if "$validate_fn" "$value"; then
      break
    fi
    gum log --level error "$errmsg"
  done
  _save "$var" "$value"
}

# Pick from a list of valid values using gum filter (fuzzy search).
# _gum_region VAR "Header" current_default
_gum_region() {
  local var="$1" header="$2" default="$3"
  _already_set "$var" "$default" && return
  local value
  value=$(printf '%s\n' "${_VALID_AWS_REGIONS[@]}" | \
    gum filter \
      --header "$header" \
      --placeholder "type to search…" \
      --value "${!var:-$default}" \
      --select-if-one \
      --limit 1)
  _save "$var" "$value"
}

# ── devenv.lock → Terraform pins ──────────────────────────────────────────────
# Exports the nixpkgs rev from devenv.lock as TF_VAR_nixpkgs_rev so the EC2
# NixOS config is pinned to the same nixpkgs as local dev and Docker builds.
_sync_devenv_lock_pins() {
  [ -f "$DEVENV_ROOT/devenv.lock" ] || return 0
  local rev
  rev=$(python3 -c "
import json; d=json.load(open('$DEVENV_ROOT/devenv.lock'))
print(d['nodes']['nixpkgs']['locked']['rev'])" 2>/dev/null) || return 0
  export TF_VAR_nixpkgs_rev="$rev"
}
_sync_devenv_lock_pins

# ── Wizard ─────────────────────────────────────────────────────────────────────

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

  _gum_input_default \
    "TF_VAR_project" \
    "Project name  (3-63 chars, lowercase, letters/digits/hyphens)" \
    "nix-ml-solo" \
    _valid_project_name \
    "Must be 3-63 lowercase chars, start with a letter, only a-z 0-9 -"

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
    local mode="${mode_label%%  *}"  # take first word before double-space
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
      ec2_type="${ec2_type%% *}"  # strip description after first space
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

  # Sync mirrored TF vars
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

      _save "AWS_AUTH_METHOD" "sso"  # commit after config is written

      if gum confirm "Run aws-login now to open the browser auth flow?"; then
        aws-login
      fi
      ;;

    *)
      # IAM user keys path
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

      # Retry loop with key ID format validation
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
      # AWS_PROFILE points to a profile that doesn't exist yet — unset so the
      # CLI uses the env-var credentials directly without a profile lookup.
      local saved_profile="${AWS_PROFILE:-}"
      unset AWS_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE

      gum log --level info "Verifying bootstrap credentials…"
      local verify_output verify_exit
      verify_output=$(aws sts get-caller-identity --output text --query 'Account' 2>&1) \
        && verify_exit=0 || verify_exit=$?

      # Restore profile env so rest of shell session uses the devenv defaults.
      [ -n "$saved_profile" ] && export AWS_PROFILE="$saved_profile"
      export AWS_CONFIG_FILE="$CONFIGS/.aws/config"
      export AWS_SHARED_CREDENTIALS_FILE="$CONFIGS/.aws/credentials"

      if [ "$verify_exit" -ne 0 ]; then
        gum log --level error "Could not authenticate: $verify_output"
        gum log --level error "Check the credentials and run 'setup' to retry."
        set +euo pipefail; return 1
      fi

      # Keep AWS_PROFILE unset for all IAM bootstrap operations; restore it after
      # _write_iam_profile creates the profile in the config file.
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

      # If we already have working credentials for this profile in the config
      # file (e.g. re-running setup after an interruption), skip key creation.
      local need_new_key=true
      if aws sts get-caller-identity \
           --profile "$profile" \
           --no-cli-pager > /dev/null 2>&1; then
        gum log --level info "Existing credentials in .devenv-configs still work — skipping key generation."
        need_new_key=false
      fi

      if [ "$need_new_key" = true ]; then
        # IAM allows max 2 keys per user. Delete the oldest if at the limit.
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

        # Overwrite any stale credentials in the config file.
        local creds="$CONFIGS/.aws/credentials"
        if grep -q "\[${profile}\]" "$creds" 2>/dev/null; then
          sed -i.bak "/^\[${profile}\]/,/^\[/{
            s|aws_access_key_id = .*|aws_access_key_id = ${new_key_id}|
            s|aws_secret_access_key = .*|aws_secret_access_key = ${new_secret}|
          }" "$creds" && rm -f "$creds.bak"
        else
          _write_iam_profile "$profile" "$new_key_id" "$new_secret" "$region"
        fi

        # Restore profile env — profile now exists in the config file.
        export AWS_PROFILE="$profile"
        export AWS_CONFIG_FILE="$CONFIGS/.aws/config"
        export AWS_SHARED_CREDENTIALS_FILE="$CONFIGS/.aws/credentials"

        # New IAM keys have eventual consistency — wait up to 45s for propagation.
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
      _save "AWS_AUTH_METHOD" "iam"  # commit only after credentials are written

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
        gum log --level info "Infrastructure deployed. Run 'mlflow-open' to open the MLflow UI."
      else
        gum log --level warn "Skipped tf-apply. Run it when ready."
      fi
    else
      gum log --level warn "Skipped. Run 'tf-bootstrap && tf-init && tf-plan && tf-apply' when ready."
    fi
  fi

  set +euo pipefail
}

if _needs_setup && [[ "$-" == *i* ]]; then
  _run_wizard
fi
