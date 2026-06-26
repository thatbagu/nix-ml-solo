#!/usr/bin/env bash
set -euo pipefail

cd "$PROJECT_ROOT/infra/terraform" && tofu apply
