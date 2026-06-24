resource "aws_s3_bucket" "dvc" {
  bucket = "${var.project}-${var.environment}-dvc"

  tags = local.tags
}

resource "aws_s3_bucket_versioning" "dvc" {
  bucket = aws_s3_bucket.dvc.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dvc" {
  bucket = aws_s3_bucket.dvc.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "dvc" {
  bucket = aws_s3_bucket.dvc.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
