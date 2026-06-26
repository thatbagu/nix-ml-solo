#!/usr/bin/env bash
set -euo pipefail

mutagen sync list "${TF_VAR_project:-nix-ml-solo}" 2>/dev/null || echo "No active sync session."
