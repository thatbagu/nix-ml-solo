variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }

variable "endpoint_name" {
  description = "SageMaker endpoint name to proxy"
  type        = string
}

variable "endpoint_arn" {
  description = "SageMaker endpoint ARN (for IAM policy)"
  type        = string
}

variable "binary" {
  description = "Accept binary payloads (images, audio, etc.) in addition to JSON"
  type        = bool
  default     = false
}
