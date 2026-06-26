#!/usr/bin/env bash
set -euo pipefail

pkill -f "ssh.*5000:localhost:5000" && echo "MLflow tunnel closed." || echo "No tunnel running."
