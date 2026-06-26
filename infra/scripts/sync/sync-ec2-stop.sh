#!/usr/bin/env bash
set -euo pipefail

mutagen sync terminate nix-ml-solo 2>/dev/null && echo "Sync session terminated." || echo "No session to stop."
