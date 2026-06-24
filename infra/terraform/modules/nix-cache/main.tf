resource "aws_s3_bucket" "nix_cache" {
  bucket = "${var.project}-${var.environment}-nix-cache"

  tags = local.tags
}

resource "aws_s3_bucket_versioning" "nix_cache" {
  bucket = aws_s3_bucket.nix_cache.id

  versioning_configuration {
    status = "Suspended" # nix store objects are content-addressed, versioning not needed
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "nix_cache" {
  bucket = aws_s3_bucket.nix_cache.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "nix_cache" {
  bucket = aws_s3_bucket.nix_cache.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: expire all objects older than 90 days (versioning is suspended,
# so expiration applies to current versions directly)
resource "aws_s3_bucket_lifecycle_configuration" "nix_cache" {
  bucket = aws_s3_bucket.nix_cache.id

  rule {
    id     = "expire-old-store-paths"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = 90
    }
  }
}

# IAM policy document for push (used by local devenv + EC2)
data "aws_iam_policy_document" "nix_cache_push" {
  statement {
    sid    = "NixCachePush"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.nix_cache.arn,
      "${aws_s3_bucket.nix_cache.arn}/*",
    ]
  }
}

# IAM policy document for pull (used by SageMaker containers)
data "aws_iam_policy_document" "nix_cache_pull" {
  statement {
    sid    = "NixCachePull"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.nix_cache.arn,
      "${aws_s3_bucket.nix_cache.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "nix_cache_push" {
  name   = "${var.project}-${var.environment}-nix-cache-push"
  policy = data.aws_iam_policy_document.nix_cache_push.json
  tags   = local.tags
}

resource "aws_iam_policy" "nix_cache_pull" {
  name   = "${var.project}-${var.environment}-nix-cache-pull"
  policy = data.aws_iam_policy_document.nix_cache_pull.json
  tags   = local.tags
}

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
