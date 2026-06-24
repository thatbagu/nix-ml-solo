output "dvc_bucket_name" {
  value = aws_s3_bucket.dvc.bucket
}

output "dvc_bucket_arn" {
  value = aws_s3_bucket.dvc.arn
}
