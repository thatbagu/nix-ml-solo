output "public_ip" {
  value = aws_instance.ml.public_ip
}

output "private_ip" {
  value = aws_instance.ml.private_ip
}

output "instance_id" {
  value = aws_instance.ml.id
}

output "sagemaker_role_arn" {
  value = aws_iam_role.sagemaker.arn
}

output "sagemaker_sg_id" {
  value = aws_security_group.sagemaker.id
}

output "subnet_ids" {
  value = data.aws_subnets.default.ids
}
