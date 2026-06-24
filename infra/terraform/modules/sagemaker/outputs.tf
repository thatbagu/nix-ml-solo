output "endpoint_name" {
  value = local.deploy ? aws_sagemaker_endpoint.endpoint[0].name : ""
}

output "endpoint_arn" {
  value = local.deploy ? aws_sagemaker_endpoint.endpoint[0].arn : ""
}
