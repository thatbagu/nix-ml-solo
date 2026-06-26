output "infra_mode" {
  value = var.infra_mode
}

output "dvc_bucket_name" {
  value = module.s3.dvc_bucket_name
}

output "dvc_remote_url" {
  value = "s3://${module.s3.dvc_bucket_name}/dvc"
}

output "nix_cache_bucket" {
  value = module.nix_cache.bucket_name
}

output "nix_cache_s3_uri" {
  value = module.nix_cache.s3_uri
}

# Cloud-only outputs — empty string in local mode

output "ec2_public_ip" {
  value = local.cloud ? module.ec2[0].public_ip : ""
}

output "mlflow_url" {
  value = local.cloud ? "http://localhost:${var.mlflow_port}  (tunnel via: mlflow-open)" : "http://localhost:${var.mlflow_port}  (local: mlflow-start)"
}

output "ecr_repo_uri" {
  value = local.cloud ? module.sagemaker_training[0].ecr_repo_uri : ""
}

output "sagemaker_endpoint_name" {
  value = local.cloud ? module.sagemaker[0].endpoint_name : ""
}

output "public_endpoint_url" {
  value = local.cloud && var.sagemaker_public_endpoint ? module.api_gateway[0].invoke_url : ""
}
