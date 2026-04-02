provider "aws" {
  region = "ap-northeast-2"  # Seoul Region
}

# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  
  tags = {
    Name        = "ai-car-sale-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-car-sale-public-subnet"
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
    Name        = "ai-car-sale-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-car-sale-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name        = "ai-car-sale-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# Route Table Association for Public Subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group for EC2 Instance
resource "aws_security_group" "instance_sg" {
  name        = "ai-car-sale-sg"
  description = "Security group for AI car sales service"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ai-car-sale-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "ai-car-sale-ec2-role"

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

# IAM Role Policy for EC2 to access S3
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-access-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:PutObject"
        ]
        Effect = "Allow"
        Resource = [
          "arn:aws:s3:::ai-car-sale-models/*",
          "arn:aws:s3:::ai-car-sale-models"
        ]
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "instance_profile" {
  name = "ai-car-sale-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# S3 Bucket for model storage
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-car-sale-models"

  tags = {
    Name        = "ai-car-sale-models"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 Bucket versioning
resource "aws_s3_bucket_versioning" "model_bucket_versioning" {
  bucket = aws_s3_bucket.model_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# EC2 Instance
resource "aws_instance" "ai_instance" {
  ami                    = "ami-04e8dfc09105861e7"  # Amazon Linux 2 AMI with GPU support
  instance_type          = "g5.2xlarge"             # GPU instance type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.instance_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.instance_profile.name
  key_name               = "ai-car-sale-key"       # You need to create this key pair in AWS

  root_block_device {
    volume_size = 100   # 100GB for OS and application
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker git python3 python3-pip
              systemctl start docker
              systemctl enable docker
              pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
              pip3 install transformers
              mkdir -p /opt/ai-car-sale
              cd /opt/ai-car-sale
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git .
              pip3 install -r requirements.txt
              # Add any additional setup commands here
              EOF

  tags = {
    Name        = "ai-car-sale-instance"
    project     = "ai-infra"
    environment = "production"
  }
}

# EBS Volume for model storage
resource "aws_ebs_volume" "model_volume" {
  availability_zone = "ap-northeast-2a"
  size              = 200
  type              = "gp3"
  
  tags = {
    Name        = "ai-car-sale-model-volume"
    project     = "ai-infra"
    environment = "production"
  }
}

# Attach EBS Volume to EC2 Instance
resource "aws_volume_attachment" "model_attachment" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.model_volume.id
  instance_id = aws_instance.ai_instance.id
}

# CloudWatch Alarm for high CPU utilization
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "ai-car-sale-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm monitors EC2 high CPU utilization"
  alarm_actions       = []  # Add SNS topic ARN if needed
  
  dimensions = {
    InstanceId = aws_instance.ai_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Elastic IP for EC2 instance
resource "aws_eip" "instance_eip" {
  domain   = "vpc"
  instance = aws_instance.ai_instance.id
  
  tags = {
    Name        = "ai-car-sale-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

output "instance_public_ip" {
  value = aws_eip.instance_eip.public_ip
}

output "instance_id" {
  value = aws_instance.ai_instance.id
}