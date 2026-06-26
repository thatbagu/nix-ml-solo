#!/usr/bin/env bash
# Clear saved config, then re-source enter-shell.sh inside an interactive bash
# so gum TUI components work. enter-shell.sh auto-triggers _run_wizard via
# _needs_setup + [[ "$-" == *i* ]], no explicit call needed here.
# exec replaces this subprocess — wizard completion returns control to fish.

rm -f "$DEVENV_ROOT/.devenv-configs/local.env"
unset AWS_AUTH_METHOD INFRA_MODE TF_VAR_infra_mode TF_VAR_ssh_public_key \
      SSH_IDENTITY_FILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

exec bash --norc --noprofile -i -c "source '$DEVENV_ROOT/infra/scripts/enter-shell.sh'"
