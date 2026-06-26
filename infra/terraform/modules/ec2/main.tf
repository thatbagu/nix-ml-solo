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

# ── VPC — use the default VPC ────────────────────────────────────────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ── Security groups ───────────────────────────────────────────────────────────

resource "aws_security_group" "ec2" {
  name        = "${var.project}-${var.environment}-ec2-sg"
  description = "Dev VM + MLflow server"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description     = "MLflow - SageMaker inference logging (private only)"
    from_port       = var.mlflow_port
    to_port         = var.mlflow_port
    protocol        = "tcp"
    security_groups = [aws_security_group.sagemaker.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Security group for SageMaker endpoint ENIs
resource "aws_security_group" "sagemaker" {
  name        = "${var.project}-${var.environment}-sagemaker-sg"
  description = "SageMaker endpoint - outbound to MLflow on EC2"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# ── VPC endpoints (so SageMaker in VPC can pull ECR images + S3 model artifacts)

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_vpc.default.main_route_table_id != null ? [data.aws_vpc.default.main_route_table_id] : []

  tags = merge(local.tags, { Name = "${var.project}-${var.environment}-s3-endpoint" })
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.sagemaker.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${var.project}-${var.environment}-ecr-api-endpoint" })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.sagemaker.id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${var.project}-${var.environment}-ecr-dkr-endpoint" })
}

locals {
  nixos_config = templatefile("${path.module}/configuration.nix.tpl", {
    mlflow_port      = var.mlflow_port
    dvc_bucket_name  = var.dvc_bucket_name
    nix_cache_bucket = var.nix_cache_bucket
    aws_region       = var.aws_region
    ssh_public_key   = var.ssh_public_key
    extra_nix_config = var.ec2_extra_nix_config
    nixpkgs_rev      = var.nixpkgs_rev
    nixpkgs_nar_hash = var.nixpkgs_nar_hash
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
