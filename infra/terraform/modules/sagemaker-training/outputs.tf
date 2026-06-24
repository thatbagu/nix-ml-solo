output "ecr_repo_uri" {
  value = aws_ecr_repository.ml.repository_url
}

output "ecr_repo_name" {
  value = aws_ecr_repository.ml.name
}

output "job_config_s3_uri" {
  value = "s3://${var.dvc_bucket_name}/training-config/job-config-template.json"
}
