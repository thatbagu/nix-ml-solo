# NixOS AMIs are published by the NixOS community on AWS.
# Owner 427812963091 is the official NixOS release account.
data "aws_ami" "nixos" {
  most_recent = true
  owners      = ["427812963091"]

  filter {
    name   = "name"
    values = ["nixos/25.05*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "ml" {
  key_name   = "${var.project}-${var.environment}-key"
  public_key = var.ssh_public_key

  tags = local.tags
}

resource "aws_security_group" "ec2" {
  name        = "${var.project}-${var.environment}-ec2-sg"
  description = "Dev VM + MLflow server"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # MLflow is NOT exposed publicly — access via SSH tunnel only
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

locals {
  nixos_config = templatefile("${path.module}/configuration.nix.tpl", {
    nixpkgs_rev      = var.nixpkgs_rev
    mlflow_port      = var.mlflow_port
    dvc_bucket_name  = var.dvc_bucket_name
    nix_cache_bucket = var.nix_cache_bucket
    aws_region       = var.aws_region
    ssh_public_key   = var.ssh_public_key
    extra_nix_config = var.ec2_extra_nix_config
  })
}

# Written to .devenv-configs/ so nixos-rebuild can push it without tf-apply.
resource "local_file" "nixos_config" {
  content  = local.nixos_config
  filename = "${path.module}/../../../../.devenv-configs/nixos-config.nix"
}

resource "aws_instance" "ml" {
  ami           = data.aws_ami.nixos.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.ml.key_name

  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  # Applied on first boot only. Use nixos-rebuild to push subsequent changes
  # without replacing the instance.
  user_data = local.nixos_config

  lifecycle {
    ignore_changes = [user_data]
  }

  tags = merge(local.tags, {
    Name = "${var.project}-${var.environment}-ml-vm"
    Role = "mlflow+training"
  })
}

# IAM role for the EC2 instance
resource "aws_iam_role" "ec2" {
  name = "${var.project}-${var.environment}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "ec2_s3" {
  name = "s3-dvc-access"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${var.dvc_bucket_name}",
        "arn:aws:s3:::${var.dvc_bucket_name}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_sagemaker" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy_attachment" "ec2_nix_cache_push" {
  role       = aws_iam_role.ec2.name
  policy_arn = var.nix_cache_push_policy_arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-${var.environment}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# SageMaker execution role
resource "aws_iam_role" "sagemaker" {
  name = "${var.project}-${var.environment}-sagemaker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sagemaker.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  role       = aws_iam_role.sagemaker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy" "sagemaker_s3" {
  name = "s3-scoped-access"
  role = aws_iam_role.sagemaker.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${var.dvc_bucket_name}",
        "arn:aws:s3:::${var.dvc_bucket_name}/*",
        "arn:aws:s3:::${var.nix_cache_bucket}",
        "arn:aws:s3:::${var.nix_cache_bucket}/*",
      ]
    }]
  })
}

locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
