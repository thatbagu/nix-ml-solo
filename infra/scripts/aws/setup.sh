#!/usr/bin/env bash
set -euo pipefail

rm -f "$DEVENV_ROOT/.devenv-configs/local.env"
unset AWS_AUTH_METHOD INFRA_MODE TF_VAR_infra_mode TF_VAR_ssh_public_key SSH_IDENTITY_FILE
source "$DEVENV_ROOT/infra/scripts/enter-shell.sh"
_run_wizard
