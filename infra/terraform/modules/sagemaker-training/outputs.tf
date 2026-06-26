output "ecr_repo_uri" {
  value = aws_ecr_repository.ml.repository_url
}

output "ecr_repo_name" {
  value = aws_ecr_repository.ml.name
}

