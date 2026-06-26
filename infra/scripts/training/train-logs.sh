#!/usr/bin/env bash
set -euo pipefail

source "$PROJECT_ROOT/infra/scripts/_lib.sh"
_require_cloud

JOB="${1:-}"
if [ -z "$JOB" ]; then
  echo "Usage: train-logs <job-name>" >&2
  exit 1
fi

aws logs tail "/aws/sagemaker/TrainingJobs" \
  --log-stream-name-prefix "$JOB" \
  --follow \
  --region "$AWS_DEFAULT_REGION"
