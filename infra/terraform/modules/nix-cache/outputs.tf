output "bucket_name" {
  value = aws_s3_bucket.nix_cache.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.nix_cache.arn
}

output "s3_uri" {
  value = "s3://${aws_s3_bucket.nix_cache.bucket}"
}

output "push_policy_arn" {
  value = aws_iam_policy.nix_cache_push.arn
}

output "pull_policy_arn" {
  value = aws_iam_policy.nix_cache_pull.arn
}
