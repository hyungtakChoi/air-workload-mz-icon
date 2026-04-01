provider "aws" {
  region = "ap-northeast-2"  # 서울 리전
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  
  tags = {
    Name        = "ai-used-car-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  
  tags = {
    Name        = "ai-used-car-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"
  
  tags = {
    Name        = "ai-used-car-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name        = "ai-used-car-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  
  tags = {
    Name        = "ai-used-car-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app_sg" {
  name        = "ai-used-car-app-sg"
  description = "Security group for AI Used Car Application"
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
    description = "Allow all outbound traffic"
  }
  
  tags = {
    Name        = "ai-used-car-app-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_iam_role" "ec2_role" {
  name = "ai-used-car-ec2-role"
  
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

resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "app_profile" {
  name = "ai-used-car-app-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-used-car-models"
  
  tags = {
    Name        = "AI Used Car Models"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_s3_bucket_ownership_controls" "model_bucket_ownership" {
  bucket = aws_s3_bucket.model_bucket.id
  
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "model_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.model_bucket_ownership]
  
  bucket = aws_s3_bucket.model_bucket.id
  acl    = "private"
}

resource "aws_instance" "app_server" {
  ami                    = "ami-0c9c942bd7bf113a2"  # Ubuntu 22.04 with NVIDIA drivers
  instance_type          = "g5.2xlarge"            # A10G GPU, 8 vCPUs, 32GB RAM
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.app_profile.name
  key_name               = "ai-used-car-key"       # 사전에 생성된 키페어 이름
  
  root_block_device {
    volume_type = "gp3"
    volume_size = 100  # 모델 및 데이터를 위한 충분한 공간
    encrypted   = true
  }
  
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3-pip git
              pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
              pip3 install transformers
              mkdir -p /app
              cd /app
              git clone https://github.com/hyungtakChoi/air-workload-mz-icon.git
              cd air-workload-mz-icon
              pip3 install -r requirements.txt
              # AWS CLI 설치 및 S3에서 모델 다운로드
              apt-get install -y awscli
              aws s3 cp s3://ai-used-car-models/models/ /app/models/ --recursive
              EOF
              
  tags = {
    Name        = "ai-used-car-app-server"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_eip" "app_eip" {
  instance = aws_instance.app_server.id
  domain   = "vpc"
  
  tags = {
    Name        = "ai-used-car-app-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_cloudwatch_metric_alarm" "gpu_utilization" {
  alarm_name          = "ai-used-car-high-gpu-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "GPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "This metric monitors EC2 GPU utilization"
  
  dimensions = {
    InstanceId = aws_instance.app_server.id
  }
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

output "app_server_public_ip" {
  description = "Public IP address of the AI application server"
  value       = aws_eip.app_eip.public_ip
}

output "model_bucket_name" {
  description = "S3 bucket name for model storage"
  value       = aws_s3_bucket.model_bucket.bucket
}