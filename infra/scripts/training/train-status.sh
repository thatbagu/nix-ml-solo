#!/usr/bin/env bash
set -euo pipefail

JOB="${1:-}"

if [ -z "$JOB" ]; then
  echo "Usage: train-status <job-name>"
  echo ""
  echo "Recent jobs:"
  aws sagemaker list-training-jobs \
    --region "$AWS_DEFAULT_REGION" \
    --sort-by CreationTime --sort-order Descending \
    --max-results 5 \
    --query 'TrainingJobSummaries[].{Name:TrainingJobName,Status:TrainingJobStatus,Created:CreationTime}' \
    --output table
  exit 0
fi

aws sagemaker describe-training-job \
  --region "$AWS_DEFAULT_REGION" \
  --training-job-name "$JOB" \
  --query '{Status:TrainingJobStatus,Start:TrainingStartTime,End:TrainingEndTime,Failure:FailureReason}' \
  --output table
