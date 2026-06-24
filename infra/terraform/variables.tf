variable "project" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "nix-ml-solo"
}

variable "infra_mode" {
  description = "local = S3+DVC only (no EC2/SageMaker). cloud = full stack."
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "cloud"], var.infra_mode)
    error_message = "infra_mode must be 'local' or 'cloud'."
  }
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use (matches AWS_PROFILE in devenv)"
  type        = string
  default     = "ml-solo"
}

# EC2
variable "ec2_instance_type" {
  description = "EC2 instance type for the dev/MLflow VM"
  type        = string
  default     = "t3.medium"
}

variable "ssh_public_key" {
  description = "SSH public key content to install on the EC2 instance (required for cloud mode)"
  type        = string
  default     = ""
}

variable "mlflow_port" {
  description = "Port MLflow server listens on inside the EC2 instance"
  type        = number
  default     = 5000
}

variable "ec2_extra_nix_config" {
  description = "Extra NixOS module attributes appended to the EC2 VM configuration"
  type        = string
  default     = ""
}

# SageMaker training
variable "sagemaker_training_image_uri" {
  description = "ECR image URI for training container (can be same as inference). Empty = ECR repo created but no default image set."
  type        = string
  default     = ""
}

# SageMaker inference
variable "sagemaker_model_image_uri" {
  description = "ECR image URI for the SageMaker model container (leave empty to skip endpoint creation)"
  type        = string
  default     = ""
}

variable "sagemaker_model_s3_uri" {
  description = "S3 URI to the model.tar.gz artifact"
  type        = string
  default     = ""
}

variable "sagemaker_instance_type" {
  description = "SageMaker inference instance type"
  type        = string
  default     = "ml.t2.medium"
}

variable "nixpkgs_rev" {
  description = "nixpkgs git revision — auto-extracted from devenv.lock by enter-shell.sh"
  type        = string
  default     = ""
}

variable "nixpkgs_nar_hash" {
  description = "nixpkgs narHash — auto-extracted from devenv.lock by enter-shell.sh"
  type        = string
  default     = ""
}

