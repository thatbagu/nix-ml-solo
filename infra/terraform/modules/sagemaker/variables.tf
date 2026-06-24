variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "model_image_uri" {
  description = "ECR image URI for the model container. Empty = skip deployment."
  type        = string
  default     = ""
}

variable "model_s3_uri" {
  description = "S3 URI to model.tar.gz. Empty = skip deployment."
  type        = string
  default     = ""
}

variable "instance_type" {
  type    = string
  default = "ml.t2.medium"
}

variable "execution_role_arn" {
  description = "IAM role ARN for SageMaker to assume"
  type        = string
}

variable "nix_cache_bucket" {
  type = string
}

variable "nix_cache_pull_policy_arn" {
  type = string
}
