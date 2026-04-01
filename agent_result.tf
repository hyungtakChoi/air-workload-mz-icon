provider "aws" {
  region = "ap-northeast-2"  # Seoul Region
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  
  tags = {
    Name        = "main-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "ap-northeast-2a"
  
  tags = {
    Name        = "public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# Private Subnet
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"
  
  tags = {
    Name        = "private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name        = "main-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  
  tags = {
    Name        = "public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# Route Table Association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group for EC2
resource "aws_security_group" "ec2" {
  name        = "ec2-sg"
  description = "Security group for EC2 instance"
  vpc_id      = aws_vpc.main.id
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name        = "ec2-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "ec2_role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM Policy for S3 Access
resource "aws_iam_policy" "s3_access" {
  name        = "S3AccessPolicy"
  description = "Policy for S3 access"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# Attach Policy to Role
resource "aws_iam_role_policy_attachment" "s3_access_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2_profile"
  role = aws_iam_role.ec2_role.name
}

# S3 Bucket for Model Storage
resource "aws_s3_bucket" "model_storage" {
  bucket = "ai-car-model-storage-${random_id.bucket_suffix.hex}"
  
  tags = {
    Name        = "AI Model Storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# Random ID for unique bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Server for AI Model
resource "aws_instance" "ai_server" {
  ami                    = "ami-0c9c942bd7bf113a2"  # Ubuntu 22.04 with CUDA in Seoul
  instance_type          = "g5.4xlarge"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = "ai-server-key"  # Ensure this key pair exists
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  
  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }
  
  user_data = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y python3-pip git
    pip3 install torch torchvision torchaudio
    pip3 install transformers
    git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git /opt/ai-app
    # Install additional dependencies as needed
  EOF
  
  tags = {
    Name        = "ai-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# Elastic IP
resource "aws_eip" "ai_server_ip" {
  instance = aws_instance.ai_server.id
  domain   = "vpc"
  
  tags = {
    Name        = "ai-server-ip"
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch Alarm for High CPU
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "ai-server-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = []  # Add SNS topic ARN if needed
  
  dimensions = {
    InstanceId = aws_instance.ai_server.id
  }
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}