#!/usr/bin/env bash
# Sourced into the interactive devenv shell via enterShell.
# Also sourced by the 'setup' command to get wizard functions in a subprocess.

CONFIGS="$DEVENV_ROOT/.devenv-configs"
LOCAL_ENV="$CONFIGS/local.env"
mkdir -p "$CONFIGS/.aws"

if [ -f "$DEVENV_ROOT/.devenv/load" ]; then
  set -a; source "$DEVENV_ROOT/.devenv/load"; set +a
fi

[ -f "$LOCAL_ENV" ] && { set -a; source "$LOCAL_ENV"; set +a; }

alias terraform=tofu

source "$DEVENV_ROOT/infra/scripts/_lib.sh"
source "$DEVENV_ROOT/infra/scripts/_wizard.sh"


# Export nixpkgs pins from devenv.lock so Terraform can pin EC2 to the same nixpkgs.
_sync_devenv_lock_pins

# Auto-trigger first-time setup wizard in interactive shells.
if _needs_setup && [[ "$-" == *i* ]]; then
  _run_wizard
fi

# Auto-start file sync in cloud mode.
[[ "$-" == *i* ]] && [ "${INFRA_MODE:-local}" = "cloud" ] && command -v mutagen &>/dev/null && sync 2>/dev/null || true

# Initialize DVC on first run (idempotent — skips if .dvc/ already exists).
[[ "$-" == *i* ]] && _init_dvc
