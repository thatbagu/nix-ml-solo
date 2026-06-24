# SageMaker resources are only created when model_image_uri is non-empty.
# During initial setup, leave sagemaker_model_image_uri = "" in tfvars.
locals {
  deploy = var.model_image_uri != "" && var.model_s3_uri != ""

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Attach nix-cache pull policy to the SageMaker execution role
# so the inference container can fetch store paths from S3 at startup
resource "aws_iam_role_policy_attachment" "sagemaker_nix_cache_pull" {
  role       = split("/", var.execution_role_arn)[1]
  policy_arn = var.nix_cache_pull_policy_arn
}

resource "aws_sagemaker_model" "model" {
  count = local.deploy ? 1 : 0

  name               = "${var.project}-${var.environment}-model"
  execution_role_arn = var.execution_role_arn

  primary_container {
    image          = var.model_image_uri
    model_data_url = var.model_s3_uri
  }

  tags = local.tags
}

resource "aws_sagemaker_endpoint_configuration" "config" {
  count = local.deploy ? 1 : 0

  name = "${var.project}-${var.environment}-endpoint-config"

  production_variants {
    variant_name           = "primary"
    model_name             = aws_sagemaker_model.model[0].name
    initial_instance_count = 1
    instance_type          = var.instance_type
    initial_variant_weight = 1.0
  }

  tags = local.tags
}

resource "aws_sagemaker_endpoint" "endpoint" {
  count = local.deploy ? 1 : 0

  name                 = "${var.project}-${var.environment}-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.config[0].name

  tags = local.tags
}
