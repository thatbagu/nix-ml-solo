variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "training_image_uri" {
  description = "ECR image URI for training container. Can be same image as inference."
  type        = string
  default     = ""
}

variable "dvc_bucket_name" {
  type = string
}

variable "nix_cache_bucket" {
  type = string
}


variable "ec2_instance_id" {
  type = string
}

variable "ec2_public_ip" {
  type = string
}
