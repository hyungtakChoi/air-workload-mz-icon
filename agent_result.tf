provider "aws" {
  region = "ap-northeast-2"  # Seoul region
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "ai-car-sales-vpc"
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
    Name        = "ai-car-sales-public-subnet"
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
    Name        = "ai-car-sales-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-car-sales-igw"
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
    Name        = "ai-car-sales-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# Route Table Association for Public Subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Security Group for EC2
resource "aws_security_group" "ec2" {
  name        = "ai-car-sales-ec2-sg"
  description = "Security group for AI Car Sales EC2 instance"
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
    description = "Allow all outbound traffic"
  }

  tags = {
    Name        = "ai-car-sales-ec2-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# EC2 Instance
resource "aws_instance" "ai_server" {
  ami                    = "ami-0c9c942bd7bf113a2"  # Amazon Linux 2 Deep Learning AMI with CUDA 11.4
  instance_type          = "g5.2xlarge"             # NVIDIA A10G 24GB GPU
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = "ai-car-sales-key"       # You need to create this key pair

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name        = "ai-car-sales-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 Bucket for Model Storage
resource "aws_s3_bucket" "model_storage" {
  bucket = "ai-car-sales-models"

  tags = {
    Name        = "ai-car-sales-models"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 Bucket for Application Data
resource "aws_s3_bucket" "app_data" {
  bucket = "ai-car-sales-data"

  tags = {
    Name        = "ai-car-sales-data"
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "ai-car-sales-ec2-role"

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
  name        = "ai-car-sales-s3-access"
  description = "Policy for EC2 to access S3 buckets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.model_storage.arn,
          "${aws_s3_bucket.model_storage.arn}/*",
          aws_s3_bucket.app_data.arn,
          "${aws_s3_bucket.app_data.arn}/*"
        ]
      }
    ]
  })
}

# Attach IAM Policy to Role
resource "aws_iam_role_policy_attachment" "s3_access_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ai-car-sales-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# Attach Instance Profile to EC2
resource "aws_instance" "ai_server_with_profile" {
  ami                    = "ami-0c9c942bd7bf113a2"  # Amazon Linux 2 Deep Learning AMI with CUDA 11.4
  instance_type          = "g5.2xlarge"             # NVIDIA A10G 24GB GPU
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = "ai-car-sales-key"
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name        = "ai-car-sales-server"
    project     = "ai-infra"
    environment = "production"
  }
}