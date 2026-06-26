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
    environment = {
      MLFLOW_TRACKING_URI = var.mlflow_tracking_uri
    }
  }

  vpc_config {
    subnets            = var.subnet_ids
    security_group_ids = [var.sagemaker_sg_id]
  }

  tags = local.tags
}

resource "aws_sagemaker_endpoint_configuration" "config" {
  count = local.deploy ? 1 : 0

  name = "${var.project}-${var.environment}-endpoint-config"

  production_variants {
    variant_name           = "primary"
    model_name             = aws_sagemaker_model.model[0].name
    initial_instance_count = var.instance_count
    instance_type          = var.instance_type
    initial_variant_weight = 1.0

    # Container pulls Nix closure from S3 + uv sync at startup — allow up to
    # 20 min before SageMaker marks the instance unhealthy. Max allowed: 3600.
    container_startup_health_check_timeout_in_seconds = 1200
  }

  tags = local.tags
}

locals {
  traffic_routing_type = {
    blue_green = "ALL_AT_ONCE"
    canary     = "CANARY"
    linear     = "LINEAR"
  }
}

resource "aws_sagemaker_endpoint" "endpoint" {
  count = local.deploy ? 1 : 0

  name                 = "${var.project}-${var.environment}-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.config[0].name

  deployment_config {
    blue_green_update_policy {
      traffic_routing_configuration {
        type                     = local.traffic_routing_type[var.deployment_strategy]
        wait_interval_in_seconds = var.deployment_strategy == "blue_green" ? 0 : var.deployment_wait_interval_seconds

        dynamic "canary_size" {
          for_each = var.deployment_strategy == "canary" ? [1] : []
          content {
            type  = "CAPACITY_IN_PERCENT"
            value = var.deployment_canary_percent
          }
        }

        dynamic "linear_step_size" {
          for_each = var.deployment_strategy == "linear" ? [1] : []
          content {
            type  = "CAPACITY_IN_PERCENT"
            value = var.deployment_linear_step_percent
          }
        }
      }
      termination_wait_in_seconds          = 0
      maximum_execution_timeout_in_seconds = 1200
    }
  }

  tags = local.tags
}

# ── Auto-scaling (opt-in: set min_capacity > 0 to enable) ────────────────────

locals {
  autoscale = local.deploy && var.min_capacity > 0
}

resource "aws_appautoscaling_target" "sagemaker" {
  count = local.autoscale ? 1 : 0

  service_namespace  = "sagemaker"
  resource_id        = "endpoint/${aws_sagemaker_endpoint.endpoint[0].name}/variant/primary"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
}

resource "aws_appautoscaling_policy" "sagemaker_invocations" {
  count = local.autoscale ? 1 : 0

  name               = "${var.project}-${var.environment}-invocations-scaling"
  service_namespace  = "sagemaker"
  resource_id        = aws_appautoscaling_target.sagemaker[0].resource_id
  scalable_dimension = aws_appautoscaling_target.sagemaker[0].scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    target_value       = var.target_invocations_per_instance
    scale_in_cooldown  = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown

    predefined_metric_specification {
      predefined_metric_type = "SageMakerVariantInvocationsPerInstance"
    }
  }
}
