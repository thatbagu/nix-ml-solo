variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ssh_public_key" {
  type = string
}

variable "mlflow_port" {
  type    = number
  default = 5000
}

variable "dvc_bucket_name" {
  type = string
}

variable "nix_cache_bucket" {
  type = string
}

variable "nix_cache_push_policy_arn" {
  type = string
}

variable "ec2_extra_nix_config" {
  description = "Extra NixOS module attributes appended to the EC2 configuration. Set via TF_VAR_ec2_extra_nix_config or root devenv.nix."
  type        = string
  default     = ""
}
