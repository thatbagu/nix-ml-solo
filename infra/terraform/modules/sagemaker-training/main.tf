# This module does NOT create a long-lived training job resource —
# SageMaker training jobs are ephemeral and triggered on demand.
# Instead it provisions the IAM role, ECR repo, and outputs everything
# the `train` devenv script needs to call CreateTrainingJob.

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ECR repo for the shared training+inference container image
resource "aws_ecr_repository" "ml" {
  name                 = "${var.project}-${var.environment}-ml"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "ml" {
  repository = aws_ecr_repository.ml.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}


# S3 prefix for training output artifacts
resource "aws_s3_object" "training_output_prefix" {
  bucket  = var.dvc_bucket_name
  key     = "training-output/.keep"
  content = ""
}

# training-job config template rendered and stored in S3 —
# the `train` script downloads this, merges with per-run overrides, submits
resource "aws_s3_object" "job_config_template" {
  bucket  = var.dvc_bucket_name
  key     = "training-config/job-config-template.json"
  content = templatefile("${path.module}/job-config-template.json.tpl", {
    project            = var.project
    environment        = var.environment
    aws_region         = var.aws_region
    execution_role_arn = var.execution_role_arn
    training_image_uri = var.training_image_uri
    dvc_bucket_name    = var.dvc_bucket_name
    nix_cache_bucket   = var.nix_cache_bucket
    ecr_repo_uri       = aws_ecr_repository.ml.repository_url
  })
}
