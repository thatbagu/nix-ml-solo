#!/usr/bin/env bash
# Shared helpers — sourced by enter-shell.sh AND standalone scripts.
# No side effects here; only function definitions.

# ── Common guards ──────────────────────────────────────────────────────────────

_require_cloud() {
  if [ "${INFRA_MODE:-local}" != "cloud" ]; then
    echo "Error: this command requires cloud mode (INFRA_MODE=cloud)." >&2; exit 1
  fi
}

_require_ssh() {
  if [ -z "${SSH_IDENTITY_FILE:-}" ] || [ ! -f "$SSH_IDENTITY_FILE" ]; then
    echo "Error: SSH_IDENTITY_FILE not set or missing. Run 'setup'." >&2; exit 1
  fi
}

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

_valid_region()       { local r="$1"; for region in "${_VALID_AWS_REGIONS[@]}"; do [ "$r" = "$region" ] && return 0; done; return 1; }
_valid_project_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{2,62}$ ]]; }
_valid_profile_name() { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]{1,63}$ ]]; }
_valid_ec2_type()     { [[ "$1" =~ ^[a-z][a-z0-9]+(\.metal|(\.[0-9]*x?large|\.medium|\.small|\.micro|\.nano))$ ]]; }
_valid_aws_key_id()   { [[ "$1" =~ ^(AKIA|ASIA)[A-Z0-9]{16}$ ]]; }
_valid_account_id()   { [[ "$1" =~ ^[0-9]{12}$ ]]; }
_valid_https_url()    { [[ "$1" =~ ^https:// ]]; }

# ── gum-backed prompt helpers ──────────────────────────────────────────────────

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

_sync_devenv_lock_pins() {
  [ -f "$DEVENV_ROOT/devenv.lock" ] || return 0
  local rev nar_hash
  rev=$(python3 -c "
import json; d=json.load(open('$DEVENV_ROOT/devenv.lock'))
print(d['nodes']['nixpkgs']['locked']['rev'])" 2>/dev/null) || return 0
  nar_hash=$(python3 -c "
import json; d=json.load(open('$DEVENV_ROOT/devenv.lock'))
print(d['nodes']['nixpkgs']['locked']['narHash'])" 2>/dev/null) || return 0
  export TF_VAR_nixpkgs_rev="$rev"
  export TF_VAR_nixpkgs_nar_hash="$nar_hash"
}

# ── DVC init (once) ────────────────────────────────────────────────────────────

_init_dvc() {
  [ -d "$DEVENV_ROOT/.dvc" ] && return 0
  [ -z "${DVC_REMOTE_URL:-}" ] && return 0
  command -v dvc &>/dev/null || command -v uv &>/dev/null || return 0
  local DVC
  DVC=$(command -v dvc 2>/dev/null || echo "uv run dvc")
  echo "Initializing DVC…"
  (
    cd "$DEVENV_ROOT"
    $DVC init --quiet
    $DVC remote add -d myremote "$DVC_REMOTE_URL"
    $DVC remote modify myremote region "${AWS_DEFAULT_REGION:-us-east-1}"
  )
  echo "DVC ready (remote: $DVC_REMOTE_URL)"
}
