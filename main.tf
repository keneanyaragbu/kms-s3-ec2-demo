provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# =============================================================
# 1. KMS KEY — the encryption key that protects S3 objects
# =============================================================
resource "aws_kms_key" "app_key" {
  description             = "Encrypts application config in S3"
  deletion_window_in_days = 7
  enable_key_rotation     = true # Auto-rotates key material annually

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowRootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowAppServerDecrypt"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.app_role.arn }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "app_key" {
  name          = "alias/app-config-key"
  target_key_id = aws_kms_key.app_key.key_id
}

# =============================================================
# 2. S3 BUCKET — encrypted with KMS, stores app config
# =============================================================
resource "aws_s3_bucket" "config" {
  bucket        = "kene-app-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # Allow terraform destroy to empty and delete
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.app_key.arn
    }
    bucket_key_enabled = true # Reduces KMS API calls and cost
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload a config file — S3 encrypts it with KMS automatically
resource "aws_s3_object" "app_config" {
  bucket  = aws_s3_bucket.config.id
  key     = "config/app.env"
  content = <<-EOF
    DB_HOST=prod-database.internal
    DB_PORT=5432
    DB_NAME=healthpulse
    API_KEY=sk-production-secret-key-12345
    APP_ENV=production
  EOF
}

# =============================================================
# 3. IAM ROLE — the "badge" EC2 wears to access S3 + KMS
# =============================================================

# Trust policy: WHO can wear this badge (only EC2)
resource "aws_iam_role" "app_role" {
  name = "AppServerRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Permissions policy: WHAT the badge allows
resource "aws_iam_role_policy" "s3_read" {
  name = "s3-config-read"
  role = aws_iam_role.app_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowReadConfigBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.config.arn}/*"
      },
      {
        Sid      = "AllowListConfigBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.config.arn
      },
      {
        Sid      = "AllowKMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.app_key.arn
      }
    ]
  })
}

# Instance profile: wraps the role so EC2 can use it
resource "aws_iam_instance_profile" "app_profile" {
  name = "AppServerProfile"
  role = aws_iam_role.app_role.name
}

# =============================================================
# 4. EC2 INSTANCE — reads encrypted config from S3 at startup
# =============================================================
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"]
}

resource "aws_key_pair" "demo" {
  key_name   = "kms-demo-key"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "app" {
  name        = "kms-demo-sg"
  description = "SSH access for KMS demo"

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.demo.key_name
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app_profile.name

  user_data = <<-EOF
    #!/bin/bash
    apt update -y
    apt install -y unzip curl

    # Install AWS CLI v2 (official method — works on any Linux)
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install

    # Read encrypted config from S3
    /usr/local/bin/aws s3 cp s3://${aws_s3_bucket.config.id}/config/app.env /opt/app.env

    echo "=== Config retrieved from encrypted S3 ===" >> /var/log/kms-demo.log
    cat /opt/app.env >> /var/log/kms-demo.log
    echo "" >> /var/log/kms-demo.log
    echo "Retrieved at: $(date)" >> /var/log/kms-demo.log
    rm -rf /tmp/awscliv2.zip /tmp/aws
  EOF

  tags = {
    Name = "kms-demo-instance"
  }
}
