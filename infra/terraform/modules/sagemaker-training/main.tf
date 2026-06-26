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
  force_delete         = true

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
