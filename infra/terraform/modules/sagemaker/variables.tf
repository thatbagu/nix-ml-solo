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

variable "instance_count" {
  type    = number
  default = 1
}

variable "min_capacity" {
  description = "Auto-scaling minimum (0 = disabled)"
  type        = number
  default     = 0
}

variable "max_capacity" {
  type    = number
  default = 4
}

variable "scale_in_cooldown" {
  type    = number
  default = 300
}

variable "scale_out_cooldown" {
  type    = number
  default = 60
}

variable "target_invocations_per_instance" {
  type    = number
  default = 100
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

variable "mlflow_tracking_uri" {
  description = "MLflow tracking URI reachable from within the VPC (EC2 private IP)"
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for SageMaker endpoint ENIs (same VPC as EC2)"
  type        = list(string)
}

variable "sagemaker_sg_id" {
  description = "Security group ID for SageMaker endpoint ENIs"
  type        = string
}

# ── Deployment strategy ───────────────────────────────────────────────────────
# blue_green — all traffic cuts over at once after new instances are healthy
# canary     — small % of traffic goes to new first, then full cutover
# linear     — traffic shifts in equal steps until fully on new
# shadow     — production traffic is mirrored to new; responses discarded (requires separate shadow variant setup)
variable "deployment_strategy" {
  description = "Endpoint update strategy: blue_green | canary | linear"
  type        = string
  default     = "blue_green"
}

variable "deployment_canary_percent" {
  description = "% of traffic sent to new variant first (canary strategy)"
  type        = number
  default     = 10
}

variable "deployment_linear_step_percent" {
  description = "% of traffic shifted per step (linear strategy)"
  type        = number
  default     = 25
}

variable "deployment_wait_interval_seconds" {
  description = "Seconds to wait between canary/linear traffic shifts"
  type        = number
  default     = 300
}
