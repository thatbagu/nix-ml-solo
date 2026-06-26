#!/usr/bin/env bash
set -euo pipefail

mutagen sync list nix-ml-solo 2>/dev/null || echo "No active sync session."
