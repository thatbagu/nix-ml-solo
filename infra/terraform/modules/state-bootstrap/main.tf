terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "project"     { type = string }
variable "environment" { type = string }
variable "aws_region"  { type = string }
variable "aws_profile" { type = string }

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  name = "${var.project}-${var.environment}-tfstate"
}

resource "aws_s3_bucket" "state" {
  bucket        = local.name
  force_destroy = false

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = "${local.name}-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

output "state_bucket" { value = aws_s3_bucket.state.bucket }
output "lock_table"   { value = aws_dynamodb_table.lock.name }
