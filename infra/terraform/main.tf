terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State is stored in S3. Run `tf-bootstrap` once, then `tf-init`.
  # Backend values are passed via -backend-config by the tf-init script —
  # Terraform does not support variable interpolation in backend blocks.
  backend "s3" {}
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  cloud = var.infra_mode == "cloud"
}

# ── Always provisioned (both modes) ─────────────────────────────────────────

module "s3" {
  source      = "./modules/s3"
  project     = var.project
  environment = var.environment
}

module "nix_cache" {
  source      = "./modules/nix-cache"
  project     = var.project
  environment = var.environment
}

# ── Cloud mode only ──────────────────────────────────────────────────────────

module "ec2" {
  count = local.cloud ? 1 : 0

  source                    = "./modules/ec2"
  project                   = var.project
  environment               = var.environment
  aws_region                = var.aws_region
  instance_type             = var.ec2_instance_type
  ssh_public_key            = var.ssh_public_key
  mlflow_port               = var.mlflow_port
  dvc_bucket_name           = module.s3.dvc_bucket_name
  nix_cache_bucket          = module.nix_cache.bucket_name
  nix_cache_push_policy_arn = module.nix_cache.push_policy_arn
  ec2_extra_nix_config      = var.ec2_extra_nix_config
  nixpkgs_rev               = var.nixpkgs_rev
  nixpkgs_nar_hash          = var.nixpkgs_nar_hash
}

module "sagemaker" {
  count = local.cloud ? 1 : 0

  source                    = "./modules/sagemaker"
  project                   = var.project
  environment               = var.environment
  aws_region                = var.aws_region
  model_image_uri                        = var.sagemaker_model_image_uri
  model_s3_uri                           = var.sagemaker_model_s3_uri
  instance_type                          = var.sagemaker_instance_type
  instance_count                         = var.sagemaker_instance_count
  min_capacity                           = var.sagemaker_min_capacity
  max_capacity                           = var.sagemaker_max_capacity
  scale_in_cooldown                      = var.sagemaker_scale_in_cooldown
  scale_out_cooldown                     = var.sagemaker_scale_out_cooldown
  target_invocations_per_instance        = var.sagemaker_target_invocations_per_instance
  execution_role_arn        = module.ec2[0].sagemaker_role_arn
  nix_cache_bucket          = module.nix_cache.bucket_name
  nix_cache_pull_policy_arn = module.nix_cache.pull_policy_arn
  mlflow_tracking_uri       = "http://${module.ec2[0].private_ip}:${var.mlflow_port}"
  subnet_ids                = module.ec2[0].subnet_ids
  sagemaker_sg_id           = module.ec2[0].sagemaker_sg_id
  deployment_strategy              = var.sagemaker_deployment_strategy
  deployment_canary_percent        = var.sagemaker_deployment_canary_percent
  deployment_linear_step_percent   = var.sagemaker_deployment_linear_step_percent
  deployment_wait_interval_seconds = var.sagemaker_deployment_wait_interval_seconds
}

module "api_gateway" {
  count = local.cloud && var.sagemaker_public_endpoint ? 1 : 0

  source        = "./modules/api-gateway-inference"
  project       = var.project
  environment   = var.environment
  aws_region    = var.aws_region
  endpoint_name = module.sagemaker[0].endpoint_name
  endpoint_arn  = module.sagemaker[0].endpoint_arn
  binary        = var.sagemaker_public_endpoint_binary
}

module "sagemaker_training" {
  count = local.cloud ? 1 : 0

  source             = "./modules/sagemaker-training"
  project            = var.project
  environment        = var.environment
  aws_region         = var.aws_region
  execution_role_arn = module.ec2[0].sagemaker_role_arn
  training_image_uri = var.sagemaker_training_image_uri
  dvc_bucket_name    = module.s3.dvc_bucket_name
  nix_cache_bucket   = module.nix_cache.bucket_name
  ec2_instance_id    = module.ec2[0].instance_id
  ec2_public_ip      = module.ec2[0].public_ip
}
