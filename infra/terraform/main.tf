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
}

module "sagemaker" {
  count = local.cloud ? 1 : 0

  source                    = "./modules/sagemaker"
  project                   = var.project
  environment               = var.environment
  aws_region                = var.aws_region
  model_image_uri           = var.sagemaker_model_image_uri
  model_s3_uri              = var.sagemaker_model_s3_uri
  instance_type             = var.sagemaker_instance_type
  execution_role_arn        = module.ec2[0].sagemaker_role_arn
  nix_cache_bucket          = module.nix_cache.bucket_name
  nix_cache_pull_policy_arn = module.nix_cache.pull_policy_arn
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
