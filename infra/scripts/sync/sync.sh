#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud

STAMPS="$DEVENV_ROOT/.devenv-configs"

# 1. Mutagen — bidirectional file sync
if ! mutagen sync list "${TF_VAR_project:-nix-ml-solo}" 2>/dev/null | grep -q "Watching"; then
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
  nix-sync && echo "$_CUR" >"$STAMPS/.last-synced-profile"
else
  echo "[ sync ] Nix cache up to date"
fi

# 3. NixOS rebuild — push devenv.nix + devenv.lock to EC2 if changed
_HASH=$(md5sum "$DEVENV_ROOT/devenv.nix" "$DEVENV_ROOT/devenv.lock" 2>/dev/null | md5sum | cut -d" " -f1)
_PREV_HASH=$(cat "$STAMPS/.last-nixos-rebuilt" 2>/dev/null || true)
if [ "$_HASH" != "$_PREV_HASH" ]; then
  echo "[ sync ] devenv.nix or devenv.lock changed — rebuilding EC2…"
  nixos-rebuild && echo "$_HASH" >"$STAMPS/.last-nixos-rebuilt"
else
  echo "[ sync ] EC2 NixOS config up to date"
fi
