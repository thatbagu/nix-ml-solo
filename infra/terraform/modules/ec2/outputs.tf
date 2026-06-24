output "public_ip" {
  value = aws_instance.ml.public_ip
}

output "instance_id" {
  value = aws_instance.ml.id
}

output "sagemaker_role_arn" {
  value = aws_iam_role.sagemaker.arn
}
