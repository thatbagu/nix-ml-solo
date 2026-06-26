#!/usr/bin/env bash
set -euo pipefail

case "${AWS_AUTH_METHOD:-iam}" in
  sso)
    echo "Logging in via IAM Identity Center (profile: $AWS_PROFILE)..."
    aws sso login --profile "$AWS_PROFILE"
    echo "Done. Run 'aws-verify' to confirm."
    ;;
  iam)
    echo "Using IAM access keys — no login needed."
    aws-verify
    ;;
  *)
    echo "Unknown AWS_AUTH_METHOD '${AWS_AUTH_METHOD}'. Run 'setup' to reconfigure." >&2
    exit 1
    ;;
esac
