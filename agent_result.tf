provider "aws" {
  region = "ap-northeast-2"
}

# VPC 생성
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "ai-infra-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "ai-infra-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "ai-infra-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 프라이빗 서브넷
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name        = "ai-infra-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "ai-infra-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# 보안 그룹 - GPU 인스턴스용
resource "aws_security_group" "gpu_instance_sg" {
  name        = "ai-infra-gpu-sg"
  description = "Security group for GPU instances"
  vpc_id      = aws_vpc.main.id

  # SSH 접속
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 웹 서비스 포트
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # API 서버 포트
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 아웃바운드 모두 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "ai-infra-gpu-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# EC2 인스턴스용 IAM 역할
resource "aws_iam_role" "ec2_role" {
  name = "ai-infra-ec2-role"

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

# S3 접근 정책
resource "aws_iam_policy" "s3_access_policy" {
  name        = "ai-infra-s3-access-policy"
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

# 역할에 정책 연결
resource "aws_iam_role_policy_attachment" "s3_policy_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

# 인스턴스 프로파일
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ai-infra-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# S3 버킷 - 모델 및 데이터 저장용
resource "aws_s3_bucket" "model_bucket" {
  bucket = "ai-infra-model-bucket"

  tags = {
    Name        = "AI Model Storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 설정
resource "aws_s3_bucket_acl" "model_bucket_acl" {
  bucket = aws_s3_bucket.model_bucket.id
  acl    = "private"
}

# GPU 인스턴스 생성 (g5.2xlarge)
resource "aws_instance" "gpu_instance" {
  ami                         = "ami-086cae3329a3f7d75" # Ubuntu 22.04 with GPU support
  instance_type               = "g5.2xlarge"
  key_name                    = "ai-infra-key"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.gpu_instance_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y python3-pip git
              pip3 install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu118
              pip3 install transformers
              pip3 install flask gunicorn
              EOF

  tags = {
    Name        = "ai-infra-gpu-instance"
    project     = "ai-infra"
    environment = "production"
  }
}

# 탄력적 IP
resource "aws_eip" "gpu_instance_eip" {
  instance = aws_instance.gpu_instance.id
  domain   = "vpc"

  tags = {
    Name        = "ai-infra-gpu-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 - CPU 사용률
resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
  alarm_name          = "ai-infra-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = []

  dimensions = {
    InstanceId = aws_instance.gpu_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# CloudWatch 알람 - 메모리 부족
resource "aws_cloudwatch_metric_alarm" "memory_alarm" {
  alarm_name          = "ai-infra-low-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "MemoryUtilization"
  namespace           = "CWAgent"
  period              = "300"
  statistic           = "Average"
  threshold           = "10"
  alarm_description   = "This metric monitors ec2 memory utilization"
  alarm_actions       = []

  dimensions = {
    InstanceId = aws_instance.gpu_instance.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력값
output "instance_public_ip" {
  description = "Public IP of the GPU instance"
  value       = aws_eip.gpu_instance_eip.public_ip
}

output "instance_id" {
  description = "ID of the GPU instance"
  value       = aws_instance.gpu_instance.id
}

output "model_bucket_name" {
  description = "S3 bucket name for model storage"
  value       = aws_s3_bucket.model_bucket.bucket
}